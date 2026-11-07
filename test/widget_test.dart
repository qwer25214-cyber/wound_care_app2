// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wound_care_app2/data/patient_repository.dart';
import 'package:wound_care_app2/main.dart';
import 'package:wound_care_app2/models/patient.dart';

class _EmptyPatientRepository implements PatientRepository {
  const _EmptyPatientRepository();

  @override
  Stream<List<PatientRecord>> watchPatients() => Stream.value(const []);

  @override
  Future<void> addPatient(Patient patient) async {}

  @override
  Future<void> deletePatient(String documentId) async {}
}

class _FakeThermalFrame implements ThermalFrame {
  const _FakeThermalFrame(this.previewBytes);

  @override
  final Uint8List previewBytes;

  @override
  double temperatureAt(Offset normalizedPosition) {
    final temperature =
        34.0 +
        (1.0 - normalizedPosition.dy) * 5.0 +
        normalizedPosition.dx * 0.5;
    return double.parse(temperature.toStringAsFixed(1));
  }
}

class _FakeWoundCameraService implements WoundCameraService {
  @override
  Future<WoundCameraCapture?> capturePair() async {
    final imageBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lS8AAAAASUVORK5CYII=',
    );
    return WoundCameraCapture(
      rgbBytes: imageBytes,
      thermalFrame: _FakeThermalFrame(imageBytes),
      captureTime: DateTime(2026, 11, 7),
    );
  }
}

void main() {
  testWidgets('shows the empty patient list state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const WoundCareApp(patientRepository: _EmptyPatientRepository()),
    );
    await tester.pumpAndSettle();

    expect(find.text('傷口預警管理系統'), findsOneWidget);
    expect(find.text('目前無病患資料'), findsOneWidget);
  });

  testWidgets('updates the selected thermal point when the image is tapped', (
    WidgetTester tester,
  ) async {
    const patient = Patient(
      bedNumber: '301-A',
      name: '測試病患',
      id: 'test-001',
      gender: '女',
      age: 70,
      bradenScore: 15,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: WoundCaptureWizardPage(
          patient: patient,
          partName: '足跟',
          cameraService: _FakeWoundCameraService(),
        ),
      ),
    );

    await tester.ensureVisible(find.text('擷取 RGB + Thermal'));
    await tester.tap(find.text('擷取 RGB + Thermal'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('下一步').first);
    await tester.tap(find.text('下一步').first);
    await tester.pumpAndSettle();

    final temperatureFinder = find.textContaining('🔴 傷口:').first;
    final temperatureBeforeTap = tester.widget<Text>(temperatureFinder).data;
    final thermalCanvas = find.byKey(const ValueKey('thermal-image-canvas'));
    await tester.ensureVisible(thermalCanvas);
    final canvasRect = tester.getRect(thermalCanvas);
    await tester.tapAt(
      Offset(
        canvasRect.left + canvasRect.width * 0.1,
        canvasRect.top + canvasRect.height * 0.1,
      ),
    );
    await tester.pump();

    expect(
      tester.widget<Text>(temperatureFinder).data,
      isNot(temperatureBeforeTap),
    );
  });
}
