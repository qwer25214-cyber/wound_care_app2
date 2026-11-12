// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'dart:async';
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

class _RecordingPatientRepository implements PatientRepository {
  final List<Patient> addedPatients = [];

  @override
  Stream<List<PatientRecord>> watchPatients() => Stream.value(const []);

  @override
  Future<void> addPatient(Patient patient) async {
    addedPatients.add(patient);
  }

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
  _FakeWoundCameraService({this.events, this.error});

  final List<String>? events;
  final Object? error;

  @override
  Future<WoundCameraCapture?> capturePair() async {
    events?.add('capture');
    if (error != null) throw error!;
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
    final events = <String>[];
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
          cameraService: _FakeWoundCameraService(events: events),
          resolveUserUid: () async {
            events.add('auth');
            return 'test-user-uid';
          },
        ),
      ),
    );

    await tester.ensureVisible(find.text('擷取 RGB + Thermal'));
    await tester.tap(find.text('擷取 RGB + Thermal'));
    await tester.pumpAndSettle();
    expect(events, ['auth', 'capture']);
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

  testWidgets('does not open the camera when anonymous auth fails', (
    WidgetTester tester,
  ) async {
    final events = <String>[];
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
          cameraService: _FakeWoundCameraService(events: events),
          resolveUserUid: () async => throw StateError('sign-in failed'),
        ),
      ),
    );

    await tester.ensureVisible(find.text('擷取 RGB + Thermal'));
    await tester.tap(find.text('擷取 RGB + Thermal'));
    await tester.pumpAndSettle();

    expect(events, isEmpty);
    expect(
      find.text('匿名登入失敗，請確認 Firebase Console 已啟用 Anonymous Auth。'),
      findsOneWidget,
    );
  });

  testWidgets('stops showing progress when anonymous auth times out', (
    WidgetTester tester,
  ) async {
    final pendingAuth = Completer<String>();
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
          resolveUserUid: () => pendingAuth.future,
        ),
      ),
    );

    await tester.ensureVisible(find.text('擷取 RGB + Thermal'));
    await tester.tap(find.text('擷取 RGB + Thermal'));
    await tester.pump();
    expect(find.text('正在驗證匿名登入...'), findsOneWidget);

    await tester.pump(const Duration(seconds: 21));
    await tester.pump();

    expect(find.text('擷取 RGB + Thermal'), findsOneWidget);
    expect(
      find.text('匿名登入失敗，請確認 Firebase Console 已啟用 Anonymous Auth。'),
      findsOneWidget,
    );
  });

  testWidgets('reports browser image-picker abort as a cancelled selection', (
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
          cameraService: _FakeWoundCameraService(
            error: Exception('AbortError: signal is aborted without reason'),
          ),
          resolveUserUid: () async => 'test-user-uid',
        ),
      ),
    );

    await tester.ensureVisible(find.text('擷取 RGB + Thermal'));
    await tester.tap(find.text('擷取 RGB + Thermal'));
    await tester.pumpAndSettle();

    expect(find.text('圖片選取已取消，請重新選取 RGB 與 Thermal 影像。'), findsOneWidget);
    expect(find.text('擷取 RGB + Thermal'), findsOneWidget);
  });

  test('scopes wound image storage paths by Firebase UID', () {
    expect(
      patientImageStorageDirectory(
        uid: 'anonymous-uid',
        patientDocId: 'patient-doc',
        uploadId: 'upload-1',
      ),
      'patient_images/anonymous-uid/patient-doc/upload-1',
    );
  });

  test('serializes Storage-backed FHIR media without embedding image data', () {
    const patient = Patient(
      bedNumber: '301-A',
      name: '測試病患',
      id: 'test-001',
      gender: '女',
      age: 70,
      bradenScore: 15,
    );
    final media = FhirMedia(
      subject: patient,
      url: 'https://storage.example.test/wound.jpg',
      title: 'RGB Optical Image',
      bodySite: '足跟',
      captureTime: DateTime(2026, 11, 7),
    );

    final content = media.toJson()['content'] as Map<String, dynamic>;
    expect(content['url'], 'https://storage.example.test/wound.jpg');
    expect(content.containsKey('data'), isFalse);
  });

  test('keeps Base64 FHIR media for JSON export compatibility', () {
    const patient = Patient(
      bedNumber: '301-A',
      name: '測試病患',
      id: 'test-001',
      gender: '女',
      age: 70,
      bradenScore: 15,
    );
    final media = FhirMedia(
      subject: patient,
      base64Data: 'aW1hZ2U=',
      title: 'RGB Optical Image',
      bodySite: '足跟',
      captureTime: DateTime(2026, 11, 7),
    );

    final content = media.toJson()['content'] as Map<String, dynamic>;
    expect(content['data'], 'aW1hZ2U=');
    expect(content.containsKey('url'), isFalse);
  });

  testWidgets('renders legacy Base64 FHIR images from memory', (
    WidgetTester tester,
  ) async {
    const imageData =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lS8AAAAASUVORK5CYII=';
    final bundle = <String, dynamic>{
      'resourceType': 'Bundle',
      'bodySite': {'text': '足跟'},
      'entry': [
        for (final title in ['RGB Optical Image', 'Thermal Infrared Image'])
          {
            'resource': {
              'resourceType': 'Media',
              'content': {'title': title, 'data': imageData},
            },
          },
      ],
    };

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DualModalOverlayCard(
              docId: 'legacy-record',
              data: bundle,
              onDelete: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNWidgets(2));
    expect(find.text('圖片資料無法解碼'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loads Storage image URLs through the injected bytes loader', (
    WidgetTester tester,
  ) async {
    const imageData =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lS8AAAAASUVORK5CYII=';
    final imageBytes = base64Decode(imageData);
    final loadedUrls = <String>[];
    final bundle = <String, dynamic>{
      'resourceType': 'Bundle',
      'bodySite': {'text': '足跟'},
      'entry': [
        for (final entry in [
          ('RGB Optical Image', 'https://storage.example.test/rgb.jpg'),
          (
            'Thermal Infrared Image',
            'https://storage.example.test/thermal.jpg',
          ),
        ])
          {
            'resource': {
              'resourceType': 'Media',
              'content': {'title': entry.$1, 'url': entry.$2},
            },
          },
      ],
    };

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DualModalOverlayCard(
              docId: 'storage-record',
              data: bundle,
              onDelete: () {},
              imageLoader: (url) async {
                loadedUrls.add(url);
                return imageBytes;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();

    expect(
      loadedUrls,
      containsAll([
        'https://storage.example.test/rgb.jpg',
        'https://storage.example.test/thermal.jpg',
      ]),
    );
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.textContaining('Storage 錯誤'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('maps Braden scores to the requested risk bands', () {
    expect(BradenScaleResult.fromScore(19).riskLevel, 'Low Risk');
    expect(BradenScaleResult.fromScore(15).riskLevel, 'Mild Risk');
    expect(BradenScaleResult.fromScore(13).riskLevel, 'Moderate Risk');
    expect(BradenScaleResult.fromScore(10).riskLevel, 'High Risk');
    expect(BradenScaleResult.fromScore(9).riskLevel, 'Severe Risk');
  });

  test('round-trips optional Braden subscale scores on Patient', () {
    const patient = Patient(
      bedNumber: '301-A',
      name: 'Test Patient',
      id: 'MRN-14',
      gender: '女',
      age: 70,
      bradenScore: 18,
      bradenSubscaleScores: {
        'sensory': 3,
        'moisture': 3,
        'activity': 3,
        'mobility': 3,
        'nutrition': 3,
        'friction': 3,
      },
    );

    final restored = Patient.fromJson(patient.toJson());
    expect(restored.bradenSubscaleScores, patient.bradenSubscaleScores);
    expect(
      Patient.fromJson({'name': 'Legacy Patient'}).bradenSubscaleScores,
      isNull,
    );
  });

  testWidgets('shows an error for an out-of-range direct Braden score', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BradenScaleAssessmentSheet())),
    );
    await tester.tap(find.text('Direct Score'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '24');
    await tester.tap(find.text('Confirm Assessment'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a score between 6 and 23.'), findsOneWidget);
  });

  testWidgets(
    'calculates the detailed Braden score as subscales are selected',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: BradenScaleAssessmentSheet())),
      );

      Future<void> selectSubscale(String key, String score) async {
        final dropdown = find.byKey(ValueKey('braden-$key'));
        await tester.ensureVisible(dropdown);
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text(score).last);
        await tester.pumpAndSettle();
      }

      await selectSubscale('sensory', '4');
      await selectSubscale('moisture', '3');
      await selectSubscale('activity', '2');
      await selectSubscale('mobility', '4');
      await selectSubscale('nutrition', '3');
      await selectSubscale('friction', '2');

      expect(find.text('Total Score: 18'), findsOneWidget);
      expect(find.text('Mild Risk'), findsOneWidget);
    },
  );

  testWidgets('registers a patient with the confirmed Braden score', (
    WidgetTester tester,
  ) async {
    final repository = _RecordingPatientRepository();
    await tester.pumpWidget(WoundCareApp(patientRepository: repository));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新增病患'));
    await tester.pumpAndSettle();
    expect(find.text('Not yet assessed'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(2), 'Test Patient');
    await tester.enterText(find.byType(TextField).at(3), 'MRN-14');
    await tester.tap(find.text('確認登錄'));
    await tester.pumpAndSettle();
    expect(
      find.text('Complete the Braden assessment before registering.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Assess Braden Scale'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Direct Score'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '14');
    await tester.tap(find.text('Confirm Assessment'));
    await tester.pumpAndSettle();

    expect(find.text('Total Score: 14'), findsOneWidget);
    expect(find.text('Moderate Risk'), findsOneWidget);

    await tester.tap(find.text('確認登錄'));
    await tester.pumpAndSettle();

    expect(repository.addedPatients, hasLength(1));
    expect(repository.addedPatients.single.bradenScore, 14);
  });
}
