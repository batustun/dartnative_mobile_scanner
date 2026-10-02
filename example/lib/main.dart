// Example app for mobile_scanner.
//
// Deliberately plain: it exists to exercise every feature the plugin claims on a
// real device, not to look good. Each control maps to one documented capability.

import 'package:dartnative/dartnative.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'dartnative_plugin_registrant.dart';

void main() {
  // Platform bindings plus every plugin's FFI symbols. Must be the first line.
  DartNativePluginRegistrant.registerAll();
  SystemChrome.defaultStyle = const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: Brightness.dark,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
  );
  runApp(const ScannerDemo());
}

/// The format presets the demo can switch between at runtime.
enum FormatPreset {
  all('Everything', <BarcodeFormat>[]),
  qrOnly('QR only', <BarcodeFormat>[BarcodeFormat.qrCode]),
  retail('EAN 13 + EAN 8', <BarcodeFormat>[
    BarcodeFormat.ean13,
    BarcodeFormat.ean8,
  ]),
  mixed('QR + PDF417 + Aztec', <BarcodeFormat>[
    BarcodeFormat.qrCode,
    BarcodeFormat.pdf417,
    BarcodeFormat.aztec,
  ]);

  const FormatPreset(this.label, this.formats);

  final String label;
  final List<BarcodeFormat> formats;
}

class ScannerDemo extends StatefulWidget {
  const ScannerDemo({super.key});

  @override
  State<ScannerDemo> createState() => _ScannerDemoState();
}

class _ScannerDemoState extends State<ScannerDemo> {
  /// A centred band covering the middle of the preview, in normalized preview
  /// coordinates.
  static const Rect _window = Rect.fromLTWH(0.1, 0.35, 0.8, 0.3);

  late final MobileScannerController _controller;

  final List<Barcode> _found = <Barcode>[];
  MobileScannerException? _error;
  FormatPreset _preset = FormatPreset.all;
  bool _useScanWindow = false;
  int _detectionCount = 0;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      formats: _preset.formats,
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
    // The controller is a ChangeNotifier, so the state line stays current without
    // any state-management package.
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onDetect(BarcodeCapture capture) {
    setState(() {
      _detectionCount++;
      for (final barcode in capture.barcodes) {
        _found.insert(0, barcode);
      }
      if (_found.length > 12) _found.removeRange(12, _found.length);
    });
  }

  void _onError(MobileScannerException error) {
    setState(() => _error = error);
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
      setState(() => _error = null);
    } on MobileScannerException catch (e) {
      // Typed errors: the whole point is being able to branch rather than parse.
      setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Size screen = MediaQuery.sizeOf(context);
    final bool landscape = screen.width > screen.height;

    // Frame the preview so it always fits on screen: portrait takes a 3:4 box
    // from the width, landscape takes a 4:3 box from the height. Computing the
    // height from the width alone, as this example first did, yields a box
    // taller than a landscape screen, which pushes the preview and any
    // scan-window overlay drawn on it off the bottom entirely.
    final double previewHeight = landscape
        ? screen.height * 0.72
        : screen.width * 4 / 3;
    final double previewWidth = landscape
        ? previewHeight * 4 / 3
        : screen.width;

    return Scaffold(
      brightness: Brightness.dark,
      backgroundColor: const Color(0xFF101014),
      appBar: AppBar(title: const Text('Mobile Scanner')),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // The preview needs definite bounds. A height computed from the width
            // frames a 3:4 portrait box; never size it with AspectRatio.
            SizedBox(
              width: previewWidth,
              height: previewHeight,
              child: Stack(
                children: <Widget>[
                  MobileScanner(
                    controller: _controller,
                    scanWindow: _useScanWindow ? _window : null,
                    onDetect: _onDetect,
                    onError: _onError,
                  ),
                  // Draws the scan window so the band can actually be aimed at.
                  // The rect is normalized to the preview, so the overlay is the
                  // same numbers scaled by this box: if the outline and the
                  // scanning region ever disagree, one of the two is wrong.
                  if (_useScanWindow)
                    Positioned(
                      left: _window.left * previewWidth,
                      top: _window.top * previewHeight,
                      width: _window.width * previewWidth,
                      height: _window.height * previewHeight,
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: const Color(0xFF9BE37B),
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _statusLine(),
                  const SizedBox(height: 12),
                  _formatPicker(),
                  const SizedBox(height: 12),
                  _lifecycleControls(),
                  const SizedBox(height: 8),
                  _cameraControls(),
                  const SizedBox(height: 8),
                  _zoomControls(),
                  const SizedBox(height: 16),
                  _errorPanel(),
                  _resultList(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusLine() {
    final String torch = switch (_controller.torchState) {
      TorchState.on => 'on',
      TorchState.off => 'off',
      TorchState.unavailable => 'none',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'state: ${_controller.state.name}',
          style: const TextStyle(fontSize: 15, color: Color(0xFF9BE37B)),
        ),
        const SizedBox(height: 2),
        Text(
          'camera: ${_controller.facingInUse?.name ?? 'not open'}'
          '  ·  torch: $torch'
          '  ·  zoom: ${_controller.zoomScale.toStringAsFixed(2)}x'
          ' (max ${_controller.maxZoomScale.toStringAsFixed(1)}x)',
          style: const TextStyle(fontSize: 13, color: Color(0xFFBBBBC4)),
        ),
        const SizedBox(height: 2),
        Text(
          'detections delivered: $_detectionCount'
          '  ·  mode: noDuplicates',
          style: const TextStyle(fontSize: 13, color: Color(0xFFBBBBC4)),
        ),
      ],
    );
  }

  Widget _formatPicker() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'formats, pushed into the native recognizer',
          style: TextStyle(fontSize: 12, color: Color(0xFF8A8A94)),
        ),
        const SizedBox(height: 6),
        SegmentedControl(
          segments: FormatPreset.values.map((p) => p.label).toList(),
          selectedIndex: _preset.index,
          onValueChanged: (index) {
            final FormatPreset next = FormatPreset.values[index];
            setState(() => _preset = next);
            _guard(() => _controller.setFormats(next.formats));
          },
        ),
      ],
    );
  }

  Widget _lifecycleControls() {
    return Row(
      children: <Widget>[
        Expanded(
          child: Button(
            title: 'Start',
            onPressed: () => _guard(_controller.start),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Button(
            title: 'Stop',
            onPressed: () => _guard(_controller.stop),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Button(
            title: 'Pause',
            onPressed: () => _guard(_controller.pause),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Button(
            title: 'Resume',
            onPressed: () => _guard(_controller.resume),
          ),
        ),
      ],
    );
  }

  Widget _cameraControls() {
    return Row(
      children: <Widget>[
        Expanded(
          child: Button(
            title: 'Torch',
            onPressed: () => _guard(_controller.toggleTorch),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Button(
            title: 'Flip camera',
            onPressed: () => _guard(_controller.switchCamera),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Button(
            title: _useScanWindow ? 'Window on' : 'Window off',
            onPressed: () => setState(() => _useScanWindow = !_useScanWindow),
          ),
        ),
      ],
    );
  }

  Widget _zoomControls() {
    final double max = _controller.maxZoomScale;
    return Row(
      children: <Widget>[
        Expanded(
          child: Button(
            title: '1x',
            onPressed: () => _guard(() => _controller.setZoomScale(1)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Button(
            title: '2x',
            onPressed: max >= 2
                ? () => _guard(() => _controller.setZoomScale(2))
                : null,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Button(
            title: 'Clear list',
            onPressed: () => setState(() {
              _found.clear();
              _detectionCount = 0;
            }),
          ),
        ),
      ],
    );
  }

  Widget _errorPanel() {
    final MobileScannerException? error = _error;
    if (error == null) return const SizedBox(height: 0);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF3A1F22),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            error.code.name,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFFFF9A9A),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            error.message,
            style: const TextStyle(fontSize: 13, color: Color(0xFFE0C0C0)),
          ),
          if (error.nativeCode != null)
            Text(
              'native: ${error.nativeCode}',
              style: const TextStyle(fontSize: 12, color: Color(0xFFB08080)),
            ),
        ],
      ),
    );
  }

  Widget _resultList() {
    if (_found.isEmpty) {
      return const Text(
        'Point the camera at a barcode.',
        style: TextStyle(fontSize: 13, color: Color(0xFF8A8A94)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final Barcode barcode in _found) _resultRow(barcode),
      ],
    );
  }

  Widget _resultRow(Barcode barcode) {
    final Rect? box = barcode.boundingBox;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C22),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            barcode.format.name,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF9BE37B),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            // rawValue is legitimately null for a binary payload, so say so
            // rather than printing an empty string.
            barcode.rawValue ?? '(no text value)',
            style: const TextStyle(fontSize: 14, color: Color(0xFFEDEDF2)),
          ),
          if (box != null)
            Text(
              'box: ${box.left.toStringAsFixed(2)}, '
              '${box.top.toStringAsFixed(2)}, '
              '${box.width.toStringAsFixed(2)} x '
              '${box.height.toStringAsFixed(2)}'
              '${barcode.cornerPoints == null ? '' : '  ·  ${barcode.cornerPoints!.length} corners'}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF7A7A84)),
            ),
          if (barcode.rawBytes != null)
            Text(
              'rawBytes: ${barcode.rawBytes!.length} bytes',
              style: const TextStyle(fontSize: 11, color: Color(0xFF7A7A84)),
            ),
        ],
      ),
    );
  }
}
