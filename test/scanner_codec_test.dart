import 'dart:convert';

import 'package:dartnative/dartnative.dart' show Offset, Rect, Size;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:mobile_scanner/src/native/scanner_codec.dart';
import 'package:test/test.dart';

Map<String, Object?> env(Object body) => decodeEnvelope(jsonEncode(body))!;

void main() {
  group('decodeEnvelope', () {
    test('decodes an object', () {
      expect(decodeEnvelope('{"a":1}'), <String, Object?>{'a': 1});
    });

    test('returns null for an empty payload', () {
      expect(decodeEnvelope(''), isNull);
    });

    test('returns null for malformed JSON instead of throwing', () {
      expect(decodeEnvelope('{not json'), isNull);
      expect(decodeEnvelope('}{'), isNull);
    });

    test('returns null for a non-object top level', () {
      expect(decodeEnvelope('[1,2,3]'), isNull);
      expect(decodeEnvelope('"text"'), isNull);
      expect(decodeEnvelope('42'), isNull);
    });
  });

  group('decodeDetection', () {
    test('decodes a full barcode', () {
      final result = decodeDetection(
        env({
          'ts': 1767225600000,
          'w': 1280,
          'h': 720,
          'b': [
            {
              'f': 'qrCode',
              'v': 'hello',
              'd': 'hello',
              'bytes': base64Encode([1, 2, 3]),
              'r': [0.1, 0.2, 0.3, 0.4],
              'c': [
                [0.1, 0.2],
                [0.4, 0.2],
                [0.4, 0.6],
                [0.1, 0.6],
              ],
            },
          ],
        }),
      )!;

      expect(result.barcodes, hasLength(1));
      final barcode = result.barcodes.single;
      expect(barcode.format, BarcodeFormat.qrCode);
      expect(barcode.rawValue, 'hello');
      expect(barcode.displayValue, 'hello');
      expect(barcode.rawBytes, [1, 2, 3]);
      expect(barcode.boundingBox, const Rect.fromLTWH(0.1, 0.2, 0.3, 0.4));
      expect(barcode.cornerPoints, hasLength(4));
      expect(barcode.cornerPoints!.first, const Offset(0.1, 0.2));
      expect(result.imageSize, const Size(1280, 720));
      expect(
        result.timestamp,
        DateTime.fromMillisecondsSinceEpoch(1767225600000),
      );
    });

    test('decodes a minimal barcode, leaving every optional field null', () {
      final result = decodeDetection(
        env({
          'b': [
            {'f': 'ean13'},
          ],
        }),
      )!;
      final barcode = result.barcodes.single;
      expect(barcode.format, BarcodeFormat.ean13);
      expect(barcode.rawValue, isNull);
      expect(barcode.displayValue, isNull);
      expect(barcode.rawBytes, isNull);
      expect(barcode.boundingBox, isNull);
      expect(barcode.cornerPoints, isNull);
    });

    test('accepts integers where doubles are expected', () {
      // JSON encoders emit 0 rather than 0.0, so the decoder must not insist.
      final result = decodeDetection(
        env({
          'b': [
            {
              'f': 'qrCode',
              'r': [0, 0, 1, 1],
            },
          ],
        }),
      )!;
      expect(
        result.barcodes.single.boundingBox,
        const Rect.fromLTWH(0, 0, 1, 1),
      );
    });

    test('decodes several barcodes from one frame', () {
      final result = decodeDetection(
        env({
          'b': [
            {'f': 'qrCode', 'v': 'a'},
            {'f': 'ean8', 'v': 'b'},
            {'f': 'pdf417', 'v': 'c'},
          ],
        }),
      )!;
      expect(result.barcodes.map((b) => b.rawValue), ['a', 'b', 'c']);
    });

    test('drops an unknown symbology but keeps the rest of the frame', () {
      final result = decodeDetection(
        env({
          'b': [
            {'f': 'microQr', 'v': 'future'},
            {'f': 'qrCode', 'v': 'known'},
          ],
        }),
      )!;
      expect(result.barcodes.map((b) => b.rawValue), ['known']);
    });

    test('returns null when every entry was unusable', () {
      expect(
        decodeDetection(
          env({
            'b': [
              {'f': 'microQr'},
              {'nope': 1},
            ],
          }),
        ),
        isNull,
      );
    });

    test('returns null for a missing or empty barcode list', () {
      expect(decodeDetection(env({'ts': 1})), isNull);
      expect(decodeDetection(env({'b': <Object>[]})), isNull);
      expect(decodeDetection(env({'b': 'not a list'})), isNull);
    });

    test('falls back to now when the timestamp is absent', () {
      final before = DateTime.now();
      final result = decodeDetection(
        env({
          'b': [
            {'f': 'qrCode'},
          ],
        }),
      )!;
      expect(
        result.timestamp.isBefore(before.subtract(const Duration(seconds: 1))),
        isFalse,
      );
    });

    test('ignores a degenerate image size', () {
      final result = decodeDetection(
        env({
          'w': 0,
          'h': 720,
          'b': [
            {'f': 'qrCode'},
          ],
        }),
      )!;
      expect(result.imageSize, isNull);
    });

    test('ignores a malformed bounding box rather than inventing one', () {
      for (final bad in <Object>[
        [0.1, 0.2, 0.3],
        [0.1, 0.2, 0.3, 0.4, 0.5],
        'nope',
        [0.1, 0.2, 0.3, 'x'],
      ]) {
        final result = decodeDetection(
          env({
            'b': [
              {'f': 'qrCode', 'r': bad},
            ],
          }),
        )!;
        expect(result.barcodes.single.boundingBox, isNull, reason: '$bad');
      }
    });

    test('rejects a non-finite bounding box', () {
      final result = decodeDetection(
        decodeEnvelope('{"b":[{"f":"qrCode","r":[0,0,1e999,1]}]}')!,
      )!;
      expect(result.barcodes.single.boundingBox, isNull);
    });

    test('drops a corner list entirely when any point is malformed', () {
      // A partially decoded outline would misrepresent the symbol's shape.
      final result = decodeDetection(
        env({
          'b': [
            {
              'f': 'qrCode',
              'c': [
                [0.1, 0.2],
                [0.3],
              ],
            },
          ],
        }),
      )!;
      expect(result.barcodes.single.cornerPoints, isNull);
    });

    test('ignores malformed base64 rather than throwing', () {
      final result = decodeDetection(
        env({
          'b': [
            {'f': 'qrCode', 'bytes': 'not!valid!base64'},
          ],
        }),
      )!;
      expect(result.barcodes.single.rawBytes, isNull);
    });

    test('ignores wrongly typed text fields', () {
      final result = decodeDetection(
        env({
          'b': [
            {'f': 'qrCode', 'v': 42, 'd': true},
          ],
        }),
      )!;
      expect(result.barcodes.single.rawValue, isNull);
      expect(result.barcodes.single.displayValue, isNull);
    });
  });

  group('decodeState', () {
    test('round-trips every state', () {
      for (final state in MobileScannerState.values) {
        expect(decodeState(env({'state': state.wireName})), state);
      }
    });

    test('returns null for an unknown or missing state', () {
      expect(decodeState(env({'state': 'levitating'})), isNull);
      expect(decodeState(env({})), isNull);
      expect(decodeState(env({'state': 7})), isNull);
    });
  });

  group('decodeError', () {
    test('decodes a full error', () {
      final error = decodeError(
        env({
          'code': 'permissionDenied',
          'message': 'user refused',
          'native': 'AVErrorApplicationIsNotAuthorized',
        }),
      );
      expect(error.code, MobileScannerErrorCode.permissionDenied);
      expect(error.message, 'user refused');
      expect(error.nativeCode, 'AVErrorApplicationIsNotAuthorized');
    });

    test('round-trips every code', () {
      for (final code in MobileScannerErrorCode.values) {
        final error = decodeError(env({'code': code.wireName, 'message': 'x'}));
        expect(error.code, code);
      }
    });

    test(
      'degrades an unknown code to nativeFailure rather than dropping it',
      () {
        // Something did fail, so swallowing the event would be worse than
        // reporting it imprecisely.
        final error = decodeError(
          env({'code': 'somethingNew', 'message': 'x'}),
        );
        expect(error.code, MobileScannerErrorCode.nativeFailure);
      },
    );

    test('supplies a message when none was given', () {
      final error = decodeError(env({'code': 'startFailed'}));
      expect(error.message, isNotEmpty);
      expect(error.nativeCode, isNull);
    });

    test('still yields an exception from an empty payload', () {
      final error = decodeError(env({}));
      expect(error.code, MobileScannerErrorCode.nativeFailure);
      expect(error.message, isNotEmpty);
    });
  });

  group('decodeTorchState and decodeZoomScale', () {
    test('round-trips every torch state', () {
      for (final state in TorchState.values) {
        expect(decodeTorchState(env({'torch': state.wireName})), state);
      }
    });

    test('returns null for an unknown torch state', () {
      expect(decodeTorchState(env({'torch': 'strobe'})), isNull);
      expect(decodeTorchState(env({})), isNull);
    });

    test('decodes a zoom scale from a double or an int', () {
      expect(decodeZoomScale(env({'scale': 2.5})), 2.5);
      expect(decodeZoomScale(env({'scale': 3})), 3.0);
      expect(decodeZoomScale(env({})), isNull);
    });
  });

  group('decodeReady', () {
    test('decodes a full report', () {
      final info = decodeReady(
        env({
          'facing': 'front',
          'torch': 'unavailable',
          'minZoom': 1.0,
          'maxZoom': 8.0,
        }),
      )!;
      expect(info.facing, CameraFacing.front);
      expect(info.torchState, TorchState.unavailable);
      expect(info.minZoomScale, 1.0);
      expect(info.maxZoomScale, 8.0);
    });

    test('defaults a missing torch to unavailable and zoom to 1.0', () {
      // Claiming a torch that was not reported would let a UI light up a button
      // that cannot work.
      final info = decodeReady(env({'facing': 'back'}))!;
      expect(info.torchState, TorchState.unavailable);
      expect(info.minZoomScale, 1.0);
      expect(info.maxZoomScale, 1.0);
    });

    test('returns null without a valid facing', () {
      expect(decodeReady(env({'torch': 'off'})), isNull);
      expect(decodeReady(env({'facing': 'sideways'})), isNull);
    });
  });

  group('decodeSupportedFormats', () {
    test('decodes a list of names', () {
      expect(decodeSupportedFormats('["qrCode","ean13"]'), {
        BarcodeFormat.qrCode,
        BarcodeFormat.ean13,
      });
    });

    test('skips unknown names so a newer native build still works', () {
      expect(decodeSupportedFormats('["qrCode","microPdf417"]'), {
        BarcodeFormat.qrCode,
      });
    });

    test('returns empty for malformed or empty input', () {
      expect(decodeSupportedFormats(''), isEmpty);
      expect(decodeSupportedFormats('nonsense'), isEmpty);
      expect(decodeSupportedFormats('{"a":1}'), isEmpty);
      expect(decodeSupportedFormats('[]'), isEmpty);
      expect(decodeSupportedFormats('[1,2,3]'), isEmpty);
    });
  });
}
