import 'dart:async';
import 'dart:core';
import 'dart:html' as html;
import 'dart:js_util';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:jsqr/jsqr.dart';
import 'package:jsqr/media.dart';

import '../../qr_code_scanner.dart';
import '../qr_code_scanner.dart';
import '../types/camera.dart';
import 'frame_data.dart';

/// Even though it has been highly modified, the origial implementation has been
/// adopted from https://github.com:treeder/jsqr_flutter
///
/// Copyright 2020 @treeder
/// Copyright 2021 The one with the braid
class WebQrView extends StatefulWidget {
  final QRViewCreatedCallback onPlatformViewCreated;
  final CameraFacing? cameraFacing;
  final double? scanArea;

  const WebQrView({
    Key? key,
    required this.onPlatformViewCreated,
    this.cameraFacing = CameraFacing.front,
    this.scanArea
  }) : super(key: key);

  @override
  _WebQrViewState createState() => _WebQrViewState();

  static html.DivElement vidDiv = html.DivElement(); // need a global for the registerViewFactory

  static Future<bool> cameraAvailable() async {
    final sources = await html.window.navigator.mediaDevices!.enumerateDevices();
    // List<String> vidIds = [];
    var hasCam = false;
    for (final e in sources) {
      if (e.kind == 'videoinput') {
        // vidIds.add(e['deviceId']);
        hasCam = true;
      }
    }
    return hasCam;
  }
}

class _WebQrViewState extends State<WebQrView> {
  final html.Worker _barcodeWorker = html.Worker('assets/packages/qr_code_scanner/assets/barcode_worker.dart.js');
  final html.MessageChannel _barcodeChannel = html.MessageChannel();
  late final StreamSubscription<html.MessageEvent> _barcodeChannelSubscription;

  html.MediaStream? _localStream;
  // html.CanvasElement canvas;
  // html.CanvasRenderingContext2D ctx;
  bool _currentlyProcessing = false;

  QRViewControllerWeb? _controller;

  Timer? timer;
  String? code;
  String? _errorMsg;
  late html.VideoElement video;
  String viewID = 'QRVIEW-' + DateTime.now().millisecondsSinceEpoch.toString();

  final StreamController<Barcode> _scanUpdateController = StreamController<Barcode>();
  late CameraFacing facing;

  Timer? _frameIntervall;
  bool capturing = false;

  @override
  void initState() {
    super.initState();
    _barcodeChannelSubscription = _barcodeChannel.port2.onMessage.listen(_onJsqrResponse);
    _barcodeWorker.postMessage({'port': _barcodeChannel.port1}, [_barcodeChannel.port1]);
    facing = widget.cameraFacing ?? CameraFacing.front;

    video = html.VideoElement();
    WebQrView.vidDiv.children = [video];
    // ignore: UNDEFINED_PREFIXED_NAME
    ui.platformViewRegistry.registerViewFactory(viewID, (int id) => WebQrView.vidDiv);
    // giving JavaScipt some time to process the DOM changes
    Timer(Duration(milliseconds: 500), () {
      start();
    });
  }

  void _onJsqrResponse(html.MessageEvent event) {
    var data = event.data?['data'] as String?;

    if (data == null) {
      capturing = false;
    } else {
      _scanUpdateController.add(Barcode(data, BarcodeFormat.qrcode, data.codeUnits));
    }
  }

  Future start() async {
    await _makeCall();
    _frameIntervall?.cancel();
    _frameIntervall = Timer.periodic(Duration(milliseconds: 200), (timer) {
      _captureFrame2();
    });
  }

  void cancel() {
    if (timer != null) {
      timer!.cancel();
      timer = null;
    }
    if (_currentlyProcessing) {
      _stopStream();
    }
  }

  @override
  void dispose() {
    cancel();
    _barcodeChannelSubscription.cancel();
    _barcodeWorker.terminate();
    super.dispose();
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> _makeCall() async {
    if (_localStream != null) {
      return;
    }

    try {
      final devices = await html.window.navigator.mediaDevices!.enumerateDevices();

      var stream = await html.window.navigator.mediaDevices?.getUserMedia({
        'video': {
          'deviceId': devices.where((d) => d.kind == 'videoinput').last.deviceId,
          // 'width': {'ideal': 4096},
          // 'height': {'ideal': 2160},
          'width': {'ideal': 1920},
          'height': {'ideal': 1080},
        },
      });
      
      _localStream = stream;
      video.srcObject = _localStream;
      video.setAttribute('playsinline', 'true'); // required to tell iOS safari we don't want fullscreen
      video.setAttribute('style', 'width: 100%; height: 100%; object-fit: cover');

      if (_controller == null) {
        _controller = QRViewControllerWeb(this);
        widget.onPlatformViewCreated(_controller!);
      }

      await video.play();
    } catch (e) {
      cancel();
      setState(() {
        _errorMsg = e.toString();
      });
      return;
    }
    if (!mounted) return;

    setState(() {
      _currentlyProcessing = true;
    });
  }

  Future<void> _stopStream() async {
    try {
      // await _localStream.dispose();
      _localStream!.getTracks().forEach((track) {
        if (track.readyState == 'live') {
          track.stop();
        }
      });
      // video.stop();
      video.srcObject = null;
      _localStream = null;
      // _localRenderer.srcObject = null;
      // ignore: empty_catches
    } catch (e) {}
  }

  Future<dynamic> _captureFrame2() async {
    if (_localStream == null) {
      return null;
    }
    if (capturing) {
      return;
    }
    
    capturing = true;
    final canvas = html.CanvasElement(width: video.videoWidth, height: video.videoHeight);
    final ctx = canvas.context2D;

    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';

    if (widget.scanArea != null) {
      var cropTarget = 300;

      var clientRatio = video.clientWidth / video.clientHeight;
      var videoRatio = video.videoWidth / video.videoHeight;

      var scaledScanArea = clientRatio < videoRatio
        ? (widget.scanArea! * (video.videoHeight / video.clientHeight)).round() // width overflows
        : (widget.scanArea! * (video.videoWidth / video.clientWidth)).round(); // height overflows

      canvas.width = min(cropTarget, scaledScanArea);
      canvas.height = min(cropTarget, scaledScanArea);

      final halfScanArea = scaledScanArea / 2;

      print('cw: ${video.clientWidth}, ch: ${video.clientHeight}, vw: ${video.videoWidth}, vh: ${video.videoHeight}, sx: ${video.videoWidth / 2 - halfScanArea}, sy: ${video.videoHeight / 2 - halfScanArea}, a: $scaledScanArea');

      ctx.drawImageScaledFromSource(video,
        video.videoWidth / 2 - halfScanArea,
        video.videoHeight / 2 - halfScanArea,
        scaledScanArea, scaledScanArea,
        0, 0, canvas.width!, canvas.height!);
    } else {
      var targetLonger = 1280;

      if (canvas.width! < canvas.height!) {
        canvas.height = targetLonger;
        canvas.width = (targetLonger * video.videoWidth / video.videoHeight).round();
      } else {
        canvas.width = targetLonger;
        canvas.height = (targetLonger * video.videoHeight / video.videoWidth).round();
      }

      print('cw: ${video.clientWidth}, ch: ${video.clientHeight}, vw: ${video.videoWidth}, vh: ${video.videoHeight}');

      ctx.drawImageScaled(video, 0, 0, canvas.width!, canvas.height!);
    }
    
    final imgData = ctx.getImageData(0, 0, canvas.width!, canvas.height!);

    _barcodeWorker.postMessage({
      'imageData': imgData.data,
      'width': canvas.width,
      'height': canvas.height
    });

    // var data = FrameData(
    //   imageData: imgData.data,
    //   width: canvas.width,
    //   height: canvas.height,
    // );

    // var code = await compute(decodeImage, data);
    
    // if (code != null) {
    //   _scanUpdateController.add(Barcode(code.data, BarcodeFormat.qrcode, code.data.codeUnits));
    // }
  }

  // static Code? decodeImage(FrameData data) {
  //   final start = DateTime.now();
  //   final code = jsQR(data.imageData, data.width, data.height);
  //   print('Decoding took ${DateTime.now().difference(start).inMilliseconds} ms');
  //   return code;
  // }

  @override
  Widget build(BuildContext context) {
    if (_errorMsg != null) {
      return Center(child: Text(_errorMsg!));
    }
    if (_localStream == null) {
      return Center(child: CircularProgressIndicator());
    }

    return HtmlElementView(viewType: viewID);
  }
}

class QRViewControllerWeb implements QRViewController {
  final _WebQrViewState _state;

  QRViewControllerWeb(this._state);
  @override
  void dispose() => _state.cancel();

  @override
  Future<CameraFacing> flipCamera() async {
    // TODO: improve error handling
    _state.facing = _state.facing == CameraFacing.front ? CameraFacing.back : CameraFacing.front;
    await _state.start();
    return _state.facing;
  }

  @override
  Future<CameraFacing> getCameraInfo() async {
    return _state.facing;
  }

  @override
  Future<bool?> getFlashStatus() async {
    // TODO: flash is simply not supported by JavaScipt. To avoid issuing applications, we always return it to be off.
    return false;
  }

  @override
  Future<SystemFeatures> getSystemFeatures() {
    // TODO: implement getSystemFeatures
    throw UnimplementedError();
  }

  @override
  // TODO: implement hasPermissions. Blocking: WebQrView.cameraAvailable() returns a Future<bool> whereas a bool is required
  bool get hasPermissions => throw UnimplementedError();

  @override
  Future<void> pauseCamera() {
    // TODO: implement pauseCamera
    throw UnimplementedError();
  }

  @override
  Future<void> resumeCamera() {
    // TODO: implement resumeCamera
    throw UnimplementedError();
  }

  @override
  Stream<Barcode> get scannedDataStream => _state._scanUpdateController.stream;

  @override
  Future<void> stopCamera() {
    // TODO: implement stopCamera
    throw UnimplementedError();
  }

  @override
  Future<void> toggleFlash() async {
    // TODO: flash is simply not supported by JavaScipt
    return;
  }
}

Widget createWebQrView({onPlatformViewCreated, CameraFacing? cameraFacing, double? scanArea}) =>
  WebQrView(
    onPlatformViewCreated: onPlatformViewCreated,
    cameraFacing: cameraFacing,
    scanArea: scanArea
  );
