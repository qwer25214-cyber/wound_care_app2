import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' show ClientException;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'data/patient_repository.dart';
import 'firebase_options.dart';
import 'models/patient.dart';

Future<String>? _initialAnonymousAuth;

Future<String> _signInAnonymouslyAndGetUid() async {
  final auth = FirebaseAuth.instance;
  final currentUser = auth.currentUser;
  if (currentUser != null) return currentUser.uid;

  final credential = await auth.signInAnonymously();
  final uid = credential.user?.uid;
  if (uid == null || uid.isEmpty) {
    throw StateError('Anonymous sign-in completed without a user UID.');
  }
  return uid;
}

Future<String> _ensureAnonymousUid() async {
  final initialAuth = _initialAnonymousAuth;
  if (initialAuth != null) {
    try {
      final uid = await initialAuth.timeout(const Duration(seconds: 20));
      if (FirebaseAuth.instance.currentUser?.uid == uid) return uid;
    } catch (_) {
      if (identical(_initialAnonymousAuth, initialAuth)) {
        _initialAnonymousAuth = null;
      }
      rethrow;
    }
  }
  return _signInAnonymouslyAndGetUid().timeout(const Duration(seconds: 20));
}

String patientImageStorageDirectory({
  required String uid,
  required String patientDocId,
  required String uploadId,
}) => 'patient_images/$uid/$patientDocId/$uploadId';

bool _isAbortError(Object error) =>
    error.toString().contains('AbortError') ||
    (error is PlatformException && error.code == 'AbortError');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  _initialAnonymousAuth = _signInAnonymouslyAndGetUid();
  unawaited(
    _initialAnonymousAuth!.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('Anonymous sign-in failed: $error');
      },
    ),
  );
  runApp(const WoundCareApp());
}

class WoundCareApp extends StatelessWidget {
  const WoundCareApp({
    super.key,
    this.patientRepository = const FirestorePatientRepository(),
  });

  final PatientRepository patientRepository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '傷口預警系統',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'NotoSansTC',
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1E1E),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        cardColor: const Color(0xFF1E1E1E),
        dialogTheme: const DialogThemeData(
          backgroundColor: Color(0xFF1E1E1E),
        ),
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueAccent,
          brightness: Brightness.dark,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
      home: PatientListPage(repository: patientRepository),
    );
  }
}

// =======================================================
// === 1. 硬體感測器介接架構 (Dependency Injection) ===
// =======================================================
abstract class ThermalFrame {
  Uint8List get previewBytes;
  double temperatureAt(Offset normalizedPosition);
}

class WoundCameraCapture {
  final Uint8List rgbBytes;
  final ThermalFrame thermalFrame;
  final DateTime captureTime;

  const WoundCameraCapture({
    required this.rgbBytes,
    required this.thermalFrame,
    required this.captureTime,
  });
}

abstract class WoundCameraService {
  Future<WoundCameraCapture?> capturePair();
}

class MockThermalFrame implements ThermalFrame {
  @override
  final Uint8List previewBytes;

  const MockThermalFrame(this.previewBytes);

  @override
  double temperatureAt(Offset normalizedPosition) {
    final temperature =
        34.0 +
        (1.0 - normalizedPosition.dy) * 5.0 +
        normalizedPosition.dx * 0.5;
    return double.parse(temperature.toStringAsFixed(1));
  }
}

class GalleryWoundCameraService implements WoundCameraService {
  final ImagePicker _picker = ImagePicker();

  @override
  Future<WoundCameraCapture?> capturePair() async {
    final photos = await _picker.pickMultiImage(
      imageQuality: 60,
      maxWidth: 600,
      maxHeight: 600,
      limit: 2,
    );
    if (photos.isEmpty) return null;
    if (photos.length != 2) {
      throw const FormatException(
        'Select exactly two images: RGB first, then Thermal.',
      );
    }

    return WoundCameraCapture(
      rgbBytes: await photos[0].readAsBytes(),
      thermalFrame: MockThermalFrame(await photos[1].readAsBytes()),
      captureTime: DateTime.now(),
    );
  }
}

abstract class TemperatureSensorService {
  Future<FhirTemperatureObservation?> captureTemperature({
    required Patient patient,
    required String bodySite,
    required DateTime captureTime,
  });
}

class MockTemperatureSensor implements TemperatureSensorService {
  @override
  Future<FhirTemperatureObservation?> captureTemperature({
    required Patient patient,
    required String bodySite,
    required DateTime captureTime,
  }) async {
    await Future.delayed(const Duration(milliseconds: 600));
    double randomTemp =
        36.0 + (DateTime.now().millisecondsSinceEpoch % 20) / 10.0;
    return FhirTemperatureObservation(
      subject: patient,
      temperature: double.parse(randomTemp.toStringAsFixed(1)),
      bodySite: bodySite,
      captureTime: captureTime,
    );
  }
}

class SensorServiceLocator {
  static final SensorServiceLocator _instance =
      SensorServiceLocator._internal();
  factory SensorServiceLocator() => _instance;
  SensorServiceLocator._internal();
  final WoundCameraService woundCamera = GalleryWoundCameraService();
  final TemperatureSensorService temperatureSensor = MockTemperatureSensor();
}

final sensorLocator = SensorServiceLocator();

// =======================================================
// === 2. 核心資料模型 (符合國際 HL7 FHIR R4 格式) ===
// =======================================================
// 🌟 核心更新：擴充了 WoundFeatureData 以符合 NPUAP 2019 壓傷指引
class WoundFeatureData {
  String stage = '第一期 (Stage 1) - 完整皮膚/指壓不白';
  String exudateAmount = '無 (None)';
  String tissueType = '完整無破損 (Intact skin)';
  String otherFeatures = '無明顯異常 (None)';
}

class WoundPhotoRecord {
  final Uint8List rgbBytes;
  final Uint8List thermalBytes;
  final WoundFeatureData features;
  final double woundTemp;
  final double referenceTemp;
  final DateTime captureTime;
  double get deltaT => woundTemp - referenceTemp;
  WoundPhotoRecord({
    required this.rgbBytes,
    required this.thermalBytes,
    required this.features,
    required this.woundTemp,
    required this.referenceTemp,
    required this.captureTime,
  });
}

class FhirMedia {
  final Patient subject;
  final String? base64Data;
  final String? url;
  final String contentType;
  final String title;
  final String bodySite;
  final DateTime captureTime;
  FhirMedia({
    required this.subject,
    this.base64Data,
    this.url,
    this.contentType = 'image/jpeg',
    required this.title,
    required this.bodySite,
    required this.captureTime,
  });
  Map<String, dynamic> toJson() => {
    "resourceType": "Media",
    "status": "completed",
    "subject": {"reference": "Patient/${subject.id}", "display": subject.name},
    "createdDateTime": captureTime.toUtc().toIso8601String(),
    "bodySite": {"text": bodySite},
    "content": {
      "contentType": contentType,
      if (url != null)
        "url": url
      else if (base64Data != null)
        "data": base64Data,
      "title": title,
    },
  };
}

Future<void> _deleteStoredMediaFromBundle(Map<String, dynamic> bundle) async {
  final entries = bundle['entry'];
  if (entries is! List) return;

  for (final entry in entries) {
    if (entry is! Map) continue;
    final resource = entry['resource'];
    if (resource is! Map || resource['resourceType'] != 'Media') continue;
    final content = resource['content'];
    final url = content is Map ? content['url'] : null;
    if (url is! String ||
        !url.startsWith('https://firebasestorage.googleapis.com/')) {
      continue;
    }

    try {
      await FirebaseStorage.instance.refFromURL(url).delete();
    } on FirebaseException catch (error) {
      if (error.code != 'object-not-found') rethrow;
    }
  }
}

class FhirTemperatureObservation {
  final Patient subject;
  final double temperature;
  final String bodySite;
  final DateTime captureTime;
  FhirTemperatureObservation({
    required this.subject,
    required this.temperature,
    required this.bodySite,
    required this.captureTime,
  });
  Map<String, dynamic> toJson() => {
    "resourceType": "Observation",
    "status": "final",
    "category": [
      {
        "coding": [
          {
            "system":
                "http://terminology.hl7.org/CodeSystem/observation-category",
            "code": "vital-signs",
            "display": "Vital Signs",
          },
        ],
      },
    ],
    "code": {
      "coding": [
        {
          "system": "http://loinc.org",
          "code": "8310-5",
          "display": "Body temperature",
        },
      ],
    },
    "subject": {"reference": "Patient/${subject.id}", "display": subject.name},
    "effectiveDateTime": captureTime.toUtc().toIso8601String(),
    "bodySite": {"text": bodySite},
    "valueQuantity": {
      "value": temperature,
      "unit": "Cel",
      "system": "http://unitsofmeasure.org",
      "code": "Cel",
    },
  };
}

class FhirWoundObservation {
  final Patient subject;
  final String bodySite;
  final double bradenScore;
  final WoundFeatureData features;
  final double woundTemp;
  final double referenceTemp;
  final DateTime captureTime;
  FhirWoundObservation({
    required this.subject,
    required this.bodySite,
    required this.bradenScore,
    required this.features,
    required this.woundTemp,
    required this.referenceTemp,
    required this.captureTime,
  });
  Map<String, dynamic> toJson() {
    double deltaT = woundTemp - referenceTemp;
    String recordIso = captureTime.toUtc().toIso8601String();

    return {
      "resourceType": "Observation",
      "status": "final",
      "category": [
        {
          "coding": [
            {
              "system":
                  "http://terminology.hl7.org/CodeSystem/observation-category",
              "code": "exam",
              "display": "Exam",
            },
          ],
        },
      ],
      "code": {
        "coding": [
          {
            "system": "http://loinc.org",
            "code": "39126-8",
            "display": "Wound assessment panel",
          },
        ],
        "text": "熱影像傷口評估報告",
      },
      "subject": {
        "reference": "Patient/${subject.id}",
        "display": subject.name,
      },
      "effectiveDateTime": recordIso,
      "bodySite": {"text": bodySite},
      "component": [
        {
          "code": {
            "coding": [
              {
                "system": "http://loinc.org",
                "code": "38228-3",
                "display": "Braden scale total score",
              },
            ],
          },
          "valueQuantity": {
            "value": bradenScore,
            "system": "http://unitsofmeasure.org",
            "code": "{score}",
          },
        },
        // 🌟 將新擴充的臨床欄位寫入 FHIR Component 中
        {
          "code": {"text": "Pressure Ulcer Stage"},
          "valueCodeableConcept": {"text": features.stage},
        },
        {
          "code": {
            "coding": [
              {
                "system": "http://loinc.org",
                "code": "72290-0",
                "display": "Exudate amount",
              },
            ],
          },
          "valueCodeableConcept": {"text": features.exudateAmount},
        },
        {
          "code": {
            "coding": [
              {
                "system": "http://loinc.org",
                "code": "72289-2",
                "display": "Tissue type in wound bed",
              },
            ],
          },
          "valueCodeableConcept": {"text": features.tissueType},
        },
        {
          "code": {"text": "Other Features (Undermining/Epibole/etc)"},
          "valueCodeableConcept": {"text": features.otherFeatures},
        },
        {
          "code": {"text": "Periwound Reference Temperature"},
          "valueQuantity": {
            "value": referenceTemp,
            "unit": "Cel",
            "system": "http://unitsofmeasure.org",
            "code": "Cel",
          },
        },
        {
          "code": {"text": "Temperature Difference (Delta T)"},
          "valueQuantity": {
            "value": double.parse(deltaT.toStringAsFixed(1)),
            "unit": "Cel",
            "system": "http://unitsofmeasure.org",
            "code": "Cel",
          },
        },
      ],
    };
  }
}

// =======================================================
// === 第一頁：病患清單 ===
// =======================================================
class BradenScaleResult {
  final int totalScore;
  final String riskLevel;
  final Map<String, int>? subscaleScores;

  const BradenScaleResult({
    required this.totalScore,
    required this.riskLevel,
    this.subscaleScores,
  });

  factory BradenScaleResult.fromScore(
    int totalScore, {
    Map<String, int>? subscaleScores,
  }) {
    if (totalScore < 6 || totalScore > 23) {
      throw RangeError.range(totalScore, 6, 23, 'totalScore');
    }
    return BradenScaleResult(
      totalScore: totalScore,
      riskLevel: riskLevelFor(totalScore),
      subscaleScores: subscaleScores == null
          ? null
          : Map.unmodifiable(subscaleScores),
    );
  }

  static String riskLevelFor(int score) {
    if (score >= 19) return 'Low Risk';
    if (score >= 15) return 'Mild Risk';
    if (score >= 13) return 'Moderate Risk';
    if (score >= 10) return 'High Risk';
    return 'Severe Risk';
  }

  static Color riskColorFor(int score) {
    if (score >= 19) return Colors.green;
    if (score >= 15) return Colors.lightGreen;
    if (score >= 13) return Colors.orange;
    if (score >= 10) return Colors.deepOrange;
    return Colors.red;
  }
}

enum _BradenInputMode { detailed, direct }

class _BradenSubscale {
  final String label;
  final int maxScore;
  final String? definition;

  const _BradenSubscale(this.label, this.maxScore, {this.definition});
}

class BradenScaleAssessmentSheet extends StatefulWidget {
  final BradenScaleResult? initialResult;

  const BradenScaleAssessmentSheet({super.key, this.initialResult});

  @override
  State<BradenScaleAssessmentSheet> createState() =>
      _BradenScaleAssessmentSheetState();
}

class _BradenScaleAssessmentSheetState
    extends State<BradenScaleAssessmentSheet> {
  static const Map<String, _BradenSubscale> _subscales = {
    'sensory': _BradenSubscale(
      'Sensory Perception',
      4,
      definition:
          'Ability to respond meaningfully to pressure-related discomfort.',
    ),
    'moisture': _BradenSubscale('Moisture', 4),
    'activity': _BradenSubscale(
      'Activity',
      4,
      definition:
          'Degree of physical activity, from bedfast to frequent walking.',
    ),
    'mobility': _BradenSubscale(
      'Mobility',
      4,
      definition: 'Ability to change and control body position independently.',
    ),
    'nutrition': _BradenSubscale('Nutrition', 4),
    'friction': _BradenSubscale('Friction and Shear', 3),
  };

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _directScoreController;
  late _BradenInputMode _mode;
  late Map<String, int?> _scores;
  bool _showDetailedError = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialResult;
    _mode = initial != null && initial.subscaleScores == null
        ? _BradenInputMode.direct
        : _BradenInputMode.detailed;
    _scores = {
      for (final key in _subscales.keys) key: initial?.subscaleScores?[key],
    };
    _directScoreController = TextEditingController(
      text: initial?.totalScore.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _directScoreController.dispose();
    super.dispose();
  }

  int? get _detailedTotal {
    if (_scores.values.any((score) => score == null)) return null;
    return _scores.values.fold<int>(0, (total, score) => total + score!);
  }

  int? get _directTotal {
    final score = int.tryParse(_directScoreController.text);
    if (score == null || score < 6 || score > 23) return null;
    return score;
  }

  int? get _currentTotal =>
      _mode == _BradenInputMode.detailed ? _detailedTotal : _directTotal;

  void _saveAssessment() {
    if (_mode == _BradenInputMode.direct) {
      if (!(_formKey.currentState?.validate() ?? false)) return;
      final score = _directTotal;
      if (score == null) return;
      Navigator.of(context).pop(BradenScaleResult.fromScore(score));
      return;
    }

    final score = _detailedTotal;
    if (score == null) {
      setState(() => _showDetailedError = true);
      return;
    }
    Navigator.of(context).pop(
      BradenScaleResult.fromScore(
        score,
        subscaleScores: {
          for (final entry in _scores.entries) entry.key: entry.value!,
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.9,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Braden Scale Assessment',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close assessment',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SegmentedButton<_BradenInputMode>(
                          segments: const [
                            ButtonSegment(
                              value: _BradenInputMode.detailed,
                              label: Text('Detailed Assessment'),
                              icon: Icon(Icons.fact_check_outlined),
                            ),
                            ButtonSegment(
                              value: _BradenInputMode.direct,
                              label: Text('Direct Score'),
                              icon: Icon(Icons.pin_outlined),
                            ),
                          ],
                          selected: {_mode},
                          onSelectionChanged: (selection) {
                            setState(() {
                              if (selection.first == _BradenInputMode.direct &&
                                  _directScoreController.text.isEmpty &&
                                  _detailedTotal != null) {
                                _directScoreController.text = _detailedTotal
                                    .toString();
                              }
                              _mode = selection.first;
                            });
                          },
                        ),
                        const SizedBox(height: 16),
                        if (_mode == _BradenInputMode.detailed)
                          _buildDetailedAssessment()
                        else
                          _buildDirectAssessment(),
                        const SizedBox(height: 16),
                        _buildRiskSummary(),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton.icon(
                      onPressed: _saveAssessment,
                      icon: const Icon(Icons.check),
                      label: const Text('Confirm Assessment'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDetailedAssessment() {
    return Column(
      children: [
        for (final entry in _subscales.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.value.label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (entry.value.definition != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        entry.value.definition!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      key: ValueKey('braden-${entry.key}'),
                      initialValue: _scores[entry.key],
                      decoration: const InputDecoration(
                        labelText: 'Score',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (
                          var score = 1;
                          score <= entry.value.maxScore;
                          score++
                        )
                          DropdownMenuItem(value: score, child: Text('$score')),
                      ],
                      onChanged: (score) {
                        setState(() {
                          _scores[entry.key] = score;
                          _showDetailedError = false;
                        });
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_showDetailedError)
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Complete all six subscales before saving.',
              style: TextStyle(color: Colors.red),
            ),
          ),
      ],
    );
  }

  Widget _buildDirectAssessment() {
    return Form(
      key: _formKey,
      child: TextFormField(
        controller: _directScoreController,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(2),
        ],
        decoration: const InputDecoration(
          labelText: 'Total score (6–23)',
          helperText: 'Enter a whole number from 6 to 23.',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.numbers),
        ),
        validator: (value) {
          final score = int.tryParse(value ?? '');
          if (score == null || score < 6 || score > 23) {
            return 'Enter a score between 6 and 23.';
          }
          return null;
        },
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Widget _buildRiskSummary() {
    final score = _currentTotal;
    if (score == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Complete the assessment to calculate the total score.'),
        ),
      );
    }
    final color = BradenScaleResult.riskColorFor(score);
    return Card(
      color: color.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Total Score: $score',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                BradenScaleResult.riskLevelFor(score),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PatientListPage extends StatefulWidget {
  const PatientListPage({super.key, required this.repository});

  final PatientRepository repository;

  @override
  State<PatientListPage> createState() => _PatientListPageState();
}

class _PatientListPageState extends State<PatientListPage> {
  late Stream<List<PatientRecord>> _patientsStream;
  String _searchQuery = '';
  @override
  void initState() {
    super.initState();
    _patientsStream = widget.repository.watchPatients();
  }

  void _showAddPatientDialog() {
    final bedController = TextEditingController();
    final nameController = TextEditingController();
    final idController = TextEditingController();
    final ageController = TextEditingController();
    String selectedGender = '男';
    BradenScaleResult? bradenResult;
    bool bradenRequiredError = false;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.person_add, color: Colors.blueAccent, size: 24),
              SizedBox(width: 8),
              Text('登錄新病患', style: TextStyle(fontSize: 18)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: bedController,
                  decoration: const InputDecoration(labelText: '床號 (如 301-A)'),
                ),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '病患姓名'),
                ),
                TextField(
                  controller: idController,
                  decoration: const InputDecoration(labelText: '病歷號'),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: ageController,
                        decoration: const InputDecoration(labelText: '年齡'),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 16),
                    DropdownButton<String>(
                      value: selectedGender,
                      items: ['男', '女']
                          .map(
                            (v) => DropdownMenuItem(value: v, child: Text(v)),
                          )
                          .toList(),
                      onChanged: (val) =>
                          setDialogState(() => selectedGender = val!),
                    ),
                  ],
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Pressure Injury Risk (Braden Scale)',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 10),
                        if (bradenResult == null)
                          Text(
                            'Not yet assessed',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          )
                        else
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                'Total Score: ${bradenResult!.totalScore}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: BradenScaleResult.riskColorFor(
                                    bradenResult!.totalScore,
                                  ),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Text(
                                  bradenResult!.riskLevel,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          height: 56,
                          child: FilledButton.tonalIcon(
                            onPressed: () async {
                              final result =
                                  await showModalBottomSheet<BradenScaleResult>(
                                    context: context,
                                    isScrollControlled: true,
                                    useSafeArea: true,
                                    builder: (_) => BradenScaleAssessmentSheet(
                                      initialResult: bradenResult,
                                    ),
                                  );
                              if (result != null) {
                                setDialogState(() {
                                  bradenResult = result;
                                  bradenRequiredError = false;
                                });
                              }
                            },
                            icon: Icon(
                              bradenResult == null ? Icons.add : Icons.edit,
                            ),
                            label: Text(
                              bradenResult == null
                                  ? 'Assess Braden Scale'
                                  : 'Edit Assessment',
                            ),
                          ),
                        ),
                        if (bradenRequiredError) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'Complete the Braden assessment before registering.',
                            style: TextStyle(color: Colors.red),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (nameController.text.isEmpty || idController.text.isEmpty) {
                  return;
                }
                if (bradenResult == null) {
                  setDialogState(() => bradenRequiredError = true);
                  return;
                }
                final newPatient = Patient(
                  bedNumber: bedController.text,
                  name: nameController.text,
                  id: idController.text,
                  gender: selectedGender,
                  age: int.tryParse(ageController.text) ?? 0,
                  bradenScore: bradenResult!.totalScore.toDouble(),
                  bradenSubscaleScores: bradenResult!.subscaleScores,
                );
                await widget.repository.addPatient(newPatient);
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('確認登錄'),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeletePatient(String docId, String patientName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('⚠️ 刪除病患', style: TextStyle(fontSize: 18)),
        content: Text(
          '確定刪除「$patientName」？\n(注意：Firestore 預設不會刪除底下的歷史紀錄)',
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.pop(context);
              await widget.repository.deletePatient(docId);
            },
            child: const Text('刪除', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '傷口預警管理系統',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60.0),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              onChanged: (value) => setState(() => _searchQuery = value.trim()),
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: InputDecoration(
                hintText: '🔍 搜尋姓名、床號或病歷號...',
                filled: true,
                fillColor: const Color(0xFF2C2C2C),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 0,
                  horizontal: 16,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 800),
            width: double.infinity,
            height: double.infinity,
            child: StreamBuilder<List<PatientRecord>>(
              stream: _patientsStream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (!snapshot.hasData || snapshot.data!.isEmpty) {
                  return const Center(
                    child: Text(
                      '目前無病患資料',
                      style: TextStyle(fontSize: 16, color: Colors.grey),
                    ),
                  );
                }
                var patientList = List<PatientRecord>.of(snapshot.data!);
                patientList.sort(
                  (a, b) =>
                      a.patient.bradenScore.compareTo(b.patient.bradenScore),
                );
                if (_searchQuery.isNotEmpty) {
                  patientList = patientList.where((item) {
                    final p = item.patient;
                    return p.name.contains(_searchQuery) ||
                        p.bedNumber.contains(_searchQuery) ||
                        p.id.contains(_searchQuery);
                  }).toList();
                }

                return ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(
                    left: 12,
                    right: 12,
                    top: 8,
                    bottom: 100,
                  ),
                  itemCount: patientList.length,
                  itemBuilder: (context, index) {
                    final record = patientList[index];
                    final docId = record.documentId;
                    final p = record.patient;
                    Color riskColor = p.bradenScore <= 12
                        ? Colors.redAccent
                        : (p.bradenScore <= 14
                              ? Colors.orangeAccent
                              : Colors.greenAccent);

                    return Card(
                      elevation: 3,
                      margin: const EdgeInsets.only(bottom: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: p.bradenScore <= 12
                              ? Colors.redAccent.withValues(alpha: 0.6)
                              : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: InkWell(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => PatientHistoryPage(
                              patient: p,
                              patientDocId: docId,
                            ),
                          ),
                        ),
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Container(
                                width: 54,
                                height: 54,
                                decoration: BoxDecoration(
                                  color: Colors.blueGrey.withValues(
                                    alpha: 0.25,
                                  ),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(
                                      Icons.hotel,
                                      color: Colors.blueAccent,
                                      size: 20,
                                    ),
                                    const SizedBox(height: 2),
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 2,
                                        ),
                                        child: Text(
                                          p.bedNumber,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.blueAccent,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            p.name.isEmpty ? '未填姓名' : p.name,
                                            style: const TextStyle(
                                              fontSize: 17,
                                              fontWeight: FontWeight.bold,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          '${p.gender} / ${p.age}歲',
                                          style: const TextStyle(
                                            color: Colors.grey,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '病歷號: ${p.id}',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 13,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: riskColor.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: riskColor.withValues(alpha: 0.6),
                                      ),
                                    ),
                                    child: Text(
                                      'Braden: ${p.bradenScore.toInt()}分',
                                      style: TextStyle(
                                        color: riskColor,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              IconButton(
                                padding: const EdgeInsets.only(left: 8),
                                constraints: const BoxConstraints(),
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.redAccent,
                                  size: 22,
                                ),
                                onPressed: () =>
                                    _confirmDeletePatient(docId, p.name),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddPatientDialog,
        icon: const Icon(Icons.person_add, size: 20),
        label: const Text('新增病患', style: TextStyle(fontSize: 15)),
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
      ),
    );
  }
}

// =======================================================
// === 歷史疊加紀錄卡 ===
// =======================================================
class _ImageLoadResult {
  final Uint8List? bytes;
  final String? error;

  const _ImageLoadResult(this.bytes, this.error);
}

typedef StorageImageLoader = Future<Uint8List?> Function(String url);

class DualModalOverlayCard extends StatefulWidget {
  final String docId;
  final Map<String, dynamic> data;
  final VoidCallback onDelete;
  final StorageImageLoader? imageLoader;
  const DualModalOverlayCard({
    super.key,
    required this.docId,
    required this.data,
    required this.onDelete,
    this.imageLoader,
  });
  @override
  State<DualModalOverlayCard> createState() => _DualModalOverlayCardState();
}

class _DualModalOverlayCardState extends State<DualModalOverlayCard> {
  double _thermalOpacity = 0.5;
  Uint8List? _rgbBytes;
  Uint8List? _thermalBytes;
  String? _rgbLoadError;
  String? _thermalLoadError;
  bool _isParsing = true;

  @override
  void initState() {
    super.initState();
    _parseImagesAsync();
  }

  @override
  void didUpdateWidget(covariant DualModalOverlayCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.docId != widget.docId) {
      _parseImagesAsync();
    }
  }

  String _extractMediaFromBundle(List<dynamic> entries, String title) {
    for (var e in entries) {
      if (e['resource'] != null &&
          e['resource']['resourceType'] == 'Media' &&
          e['resource']['content'] != null &&
          e['resource']['content']['title'] == title) {
        return e['resource']['content']['url'] ??
            e['resource']['content']['data'] ??
            '';
      }
    }
    return '';
  }

  Future<void> _parseImagesAsync() async {
    setState(() => _isParsing = true);
    await Future.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    try {
      String rgbBase64 = '';
      String thermalBase64 = '';

      bool isBundle = widget.data['resourceType'] == 'Bundle';
      if (isBundle) {
        List<dynamic> entries = widget.data['entry'] ?? [];
        rgbBase64 = _extractMediaFromBundle(entries, 'RGB Optical Image');
        thermalBase64 = _extractMediaFromBundle(
          entries,
          'Thermal Infrared Image',
        );
      } else {
        List<dynamic> comps = widget.data['component'] ?? [];
        rgbBase64 = _extractValLegacy(
          comps,
          'RGB Optical Image',
          'Wound image',
        );
        thermalBase64 = _extractValLegacy(
          comps,
          'Thermal Infrared Image',
          'Thermal Image',
        );
      }
      final imageResults = await Future.wait<_ImageLoadResult>([
        _loadImageBytes(rgbBase64),
        _loadImageBytes(thermalBase64),
      ]);
      final rgbResult = imageResults[0];
      final thermalResult = imageResults[1];
      _rgbBytes = rgbResult.bytes;
      _rgbLoadError = rgbResult.error;
      _thermalBytes = thermalResult.bytes;
      _thermalLoadError = thermalResult.error;
    } catch (e) {
      debugPrint('圖片解析異常: $e');
    } finally {
      if (mounted) setState(() => _isParsing = false);
    }
  }

  Future<_ImageLoadResult> _loadImageBytes(String? source) async {
    if (source == null || source.trim().isEmpty) {
      return const _ImageLoadResult(null, null);
    }

    final value = source.trim();
    try {
      if (value.startsWith('https://') || value.startsWith('http://')) {
        final imageLoader = widget.imageLoader;
        if (imageLoader == null) await _ensureAnonymousUid();
        final bytes =
            await (imageLoader?.call(value) ??
                FirebaseStorage.instance
                    .refFromURL(value)
                    .getData(10 * 1024 * 1024));
        if (bytes == null || bytes.isEmpty) {
          return const _ImageLoadResult(null, 'Storage 回傳空白圖片');
        }
        return _ImageLoadResult(bytes, null);
      }

      var base64Data = value;
      if (base64Data.startsWith('data:image/')) {
        final separator = base64Data.indexOf(',');
        if (separator < 0) {
          throw const FormatException('Image data URI is missing its payload.');
        }
        base64Data = base64Data.substring(separator + 1);
      }
      base64Data = base64Data
          .replaceAll('\n', '')
          .replaceAll('\r', '')
          .replaceAll(' ', '')
          .replaceAll('-', '+')
          .replaceAll('_', '/');
      final padding = base64Data.length % 4;
      if (padding != 0) base64Data += '=' * (4 - padding);
      return _ImageLoadResult(base64Decode(base64Data), null);
    } catch (error) {
      debugPrint('圖片載入失敗: $error');
      if (error is FirebaseException) {
        return _ImageLoadResult(null, 'Storage 錯誤: ${error.code}');
      }
      if (error is ClientException) {
        return const _ImageLoadResult(
          null,
          '瀏覽器無法讀取 Storage，請確認 bucket CORS 網址設定及網路連線。',
        );
      }
      return _ImageLoadResult(null, '圖片載入失敗 (${error.runtimeType})');
    }
  }

  String _formatDateSafe(Map<String, dynamic> data) {
    if (data['effectiveDateTime'] != null) {
      try {
        DateTime d = DateTime.parse(data['effectiveDateTime']).toLocal();
        return '${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
      } catch (_) {}
    }
    dynamic t = data['timestamp'];
    if (t == null) return '剛剛記錄';
    if (t is Timestamp) {
      DateTime d = t.toDate();
      return '${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    }
    return t.toString();
  }

  String _extractBundleComponent(
    List<dynamic> entries,
    String code, {
    bool isText = false,
  }) {
    for (var e in entries) {
      if (e['resource'] != null &&
          e['resource']['resourceType'] == 'Observation' &&
          e['resource']['code']?['coding']?[0]?['code'] == '39126-8') {
        List<dynamic> comps = e['resource']['component'] ?? [];
        for (var c in comps) {
          if (isText) {
            if (c['code']?['text'] == code) {
              return c['valueCodeableConcept']?['text'] ??
                  c['valueQuantity']?['value']?.toString() ??
                  '';
            }
          } else {
            if (c['code']?['coding']?[0]?['code'] == code) {
              if (c['valueCodeableConcept'] != null) {
                return c['valueCodeableConcept']['text'] ?? '';
              }
              if (c['valueQuantity'] != null) {
                return c['valueQuantity']['value']?.toString() ?? '';
              }
            }
          }
        }
      }
    }
    return '';
  }

  String _extractVitalSignFromBundle(List<dynamic> entries, String loinc) {
    for (var e in entries) {
      if (e['resource'] != null &&
          e['resource']['resourceType'] == 'Observation' &&
          e['resource']['code']?['coding']?[0]?['code'] == loinc) {
        return e['resource']['valueQuantity']?['value']?.toString() ?? '';
      }
    }
    return '';
  }

  String _extractValLegacy(
    List<dynamic> comps,
    String txt, [
    String? loincDisplay,
  ]) {
    try {
      for (var c in comps) {
        if (c is Map && c['code'] != null) {
          bool match = false;
          if (c['code']['text'] == txt) {
            match = true;
          }
          if (loincDisplay != null &&
              c['code']['coding'] != null &&
              c['code']['coding'][0]['display'] == loincDisplay) {
            match = true;
          }

          if (match) {
            if (c['valueCodeableConcept'] != null) {
              return c['valueCodeableConcept']['text'];
            }
            if (c['valueString'] != null) {
              return c['valueString'];
            }
            if (c['valueAttachment'] != null &&
                c['valueAttachment']['data'] != null) {
              return c['valueAttachment']['data'];
            }
            if (c['valueQuantity'] != null &&
                c['valueQuantity']['value'] != null) {
              return c['valueQuantity']['value'].toString();
            }
          }
        }
      }
    } catch (_) {
      return '';
    }
    return '';
  }

  Widget _buildImageProvider(Uint8List? bytes, String? error) {
    if (bytes != null && bytes.isNotEmpty) {
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        width: double.infinity,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
        errorBuilder: (context, error, stackTrace) =>
            _buildImageError('圖片資料格式無效'),
      );
    }
    return _buildImageError(error ?? '找不到圖片連結');
  }

  Widget _buildImageError(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image, color: Colors.redAccent, size: 36),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    bool isBundle = widget.data['resourceType'] == 'Bundle';
    String stage = '';
    String exudate = '';
    String tissue = '';
    String woundTempStr = '';
    String deltaTStr = '';

    if (isBundle) {
      List<dynamic> entries = widget.data['entry'] ?? [];
      stage = _extractBundleComponent(
        entries,
        'Pressure Ulcer Stage',
        isText: true,
      );
      exudate = _extractBundleComponent(entries, '72290-0');
      tissue = _extractBundleComponent(entries, '72289-2');
      woundTempStr = _extractVitalSignFromBundle(entries, '8310-5');
      deltaTStr = _extractBundleComponent(
        entries,
        'Temperature Difference (Delta T)',
        isText: true,
      );
    } else {
      List<dynamic> comps = widget.data['component'] ?? [];
      stage = _extractValLegacy(comps, 'Pressure Ulcer Stage');
      exudate = _extractValLegacy(
        comps,
        'Exudate Amount (滲液量)',
        'Exudate amount',
      );
      tissue = _extractValLegacy(
        comps,
        'Tissue Type (傷口組織)',
        'Tissue type in wound bed',
      );
      woundTempStr = _extractValLegacy(
        comps,
        'Wound Center Temperature',
        'Body temperature',
      );
      deltaTStr = _extractValLegacy(comps, 'Temperature Difference (Delta T)');
    }

    double? deltaT = double.tryParse(deltaTStr);
    Color deltaColor = Colors.grey;
    String alertText = '溫差評估';
    if (deltaT != null) {
      if (deltaT <= -0.1) {
        // 🌟 根據文獻，加入缺血 DTI 預警判斷
        deltaColor = Colors.purpleAccent;
        alertText = '❄️ 低溫缺血警示 (ΔT $deltaT°C)';
      } else if (deltaT >= 2.0) {
        deltaColor = Colors.redAccent;
        alertText = '🔥 顯著發炎 (ΔT +$deltaT°C)';
      } else if (deltaT >= 1.0) {
        deltaColor = Colors.amberAccent;
        alertText = '⚠️ 輕度充血 (ΔT +$deltaT°C)';
      } else {
        deltaColor = Colors.greenAccent;
        alertText = '✅ 正常範圍 (ΔT $deltaT°C)';
      }
    }

    return Card(
      elevation: 4,
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.accessibility_new,
                  color: Colors.blueAccent,
                  size: 20,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    (widget.data['bodySite'] != null)
                        ? widget.data['bodySite']['text'] ?? '未知部位'
                        : '未知部位',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  _formatDateSafe(widget.data),
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
                IconButton(
                  padding: const EdgeInsets.only(left: 8),
                  constraints: const BoxConstraints(),
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                    size: 22,
                  ),
                  onPressed: widget.onDelete,
                ),
              ],
            ),
            const Divider(height: 16, color: Colors.white12),

            // 🌟 顯示完整的壓傷分級與特徵
            if (stage.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '📌 分級: $stage',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.blueAccent,
                  ),
                ),
              ),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Wrap(
                alignment: WrapAlignment.start,
                runSpacing: 6,
                spacing: 10,
                children: [
                  Text(
                    '💧 滲液: ${exudate.isEmpty ? '未評估' : exudate}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.amberAccent,
                    ),
                  ),
                  Text(
                    '🔬 組織: ${tissue.isEmpty ? '未評估' : tissue}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.lightGreenAccent,
                    ),
                  ),
                  if (woundTempStr.isNotEmpty)
                    Text(
                      '🌡️ 傷口: $woundTempStr°C',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                ],
              ),
            ),
            if (deltaT != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 8),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: deltaColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: deltaColor.withValues(alpha: 0.5)),
                ),
                child: Center(
                  child: Text(
                    alertText,
                    style: TextStyle(
                      color: deltaColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                color: Colors.black,
                width: double.infinity,
                child: _isParsing
                    ? const AspectRatio(
                        aspectRatio: 4 / 3,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : AspectRatio(
                        aspectRatio: 4 / 3,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            _buildImageProvider(_rgbBytes, _rgbLoadError),
                            Positioned.fill(
                              child: Opacity(
                                opacity: _thermalOpacity,
                                child: _buildImageProvider(
                                  _thermalBytes,
                                  _thermalLoadError,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text(
                  '光學',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.blueAccent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: _thermalOpacity,
                    min: 0.0,
                    max: 1.0,
                    activeColor: Colors.deepOrangeAccent,
                    inactiveColor: Colors.blueAccent.withValues(alpha: 0.3),
                    onChanged: (v) => setState(() => _thermalOpacity = v),
                  ),
                ),
                const Text(
                  '透視',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.deepOrangeAccent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// =======================================================
// === 第二頁：歷史紀錄頁 (時間軸 Timeline 版 + 匯出 JSON) ===
// =======================================================
class PatientHistoryPage extends StatefulWidget {
  final Patient patient;
  final String patientDocId;
  const PatientHistoryPage({
    super.key,
    required this.patient,
    required this.patientDocId,
  });
  @override
  State<PatientHistoryPage> createState() => _PatientHistoryPageState();
}

class _PatientHistoryPageState extends State<PatientHistoryPage> {
  late Stream<QuerySnapshot> _historyStream;
  String _selectedSite = '全部';

  @override
  void initState() {
    super.initState();
    _historyStream = FirebaseFirestore.instance
        .collection('patients')
        .doc(widget.patientDocId)
        .collection('observations')
        .snapshots();
  }

  Future<void> _exportHistoryJson() async {
    try {
      final querySnapshot = await FirebaseFirestore.instance
          .collection('patients')
          .doc(widget.patientDocId)
          .collection('observations')
          .get();
      if (querySnapshot.docs.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ 目前無歷史紀錄可匯出', style: TextStyle(fontSize: 15)),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }
      List<Map<String, dynamic>> exportList = [];

      dynamic sanitize(dynamic item) {
        if (item is Timestamp) return item.toDate().toUtc().toIso8601String();
        if (item is Map) {
          Map<String, dynamic> clean = {};
          item.forEach((key, value) {
            if (key == 'timestamp') return;
            clean[key.toString()] = sanitize(value);
          });
          return clean;
        }
        if (item is List) {
          return item.map((e) => sanitize(e)).toList();
        }
        return item;
      }

      for (var doc in querySnapshot.docs) {
        var data = doc.data();
        if (_selectedSite != '全部') {
          String site = data['bodySite']?['text'] ?? '';
          if (site != _selectedSite) continue;
        }
        exportList.add(sanitize(data));
      }
      if (exportList.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ 該部位無紀錄可匯出', style: TextStyle(fontSize: 15)),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }
      JsonEncoder encoder = const JsonEncoder.withIndent('  ');
      String jsonString = encoder.convert(exportList);
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.data_object, color: Colors.blueAccent),
              SizedBox(width: 8),
              Text('匯出歷史 FHIR JSON'),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 400,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  jsonString,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: Colors.greenAccent,
                  ),
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('關閉', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: jsonString));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        '✅ JSON 已複製到剪貼簿！',
                        style: TextStyle(fontSize: 14),
                      ),
                      backgroundColor: Colors.green,
                    ),
                  );
                  Navigator.pop(context);
                }
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('複製全部'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
              ),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('匯出失敗: $e', style: const TextStyle(fontSize: 14)),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.patient.name} - 歷程時間軸',
          style: const TextStyle(fontSize: 18),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 800),
            width: double.infinity,
            height: double.infinity,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 16,
                  ),
                  color: const Color(0xFF1E1E1E),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _infoItem(Icons.hotel, '床號', widget.patient.bedNumber),
                      _infoItem(Icons.badge, '病歷號', widget.patient.id),
                      _infoItem(
                        Icons.analytics,
                        'Braden',
                        '${widget.patient.bradenScore.toInt()}分',
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: _historyStream,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState ==
                          ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                        return const Center(
                          child: Text(
                            '目前無歷史紀錄，請新增',
                            style: TextStyle(color: Colors.grey, fontSize: 16),
                          ),
                        );
                      }

                      var docs = snapshot.data!.docs;

                      Set<String> sites = {'全部'};
                      for (var d in docs) {
                        String s = (d.data() as Map)['bodySite']?['text'] ?? '';
                        if (s.isNotEmpty) sites.add(s);
                      }

                      var filteredDocs = docs;
                      if (_selectedSite != '全部') {
                        filteredDocs = docs
                            .where(
                              (d) =>
                                  ((d.data() as Map)['bodySite']?['text'] ??
                                      '') ==
                                  _selectedSite,
                            )
                            .toList();
                              }

                      // 🌟 時間軸日期分組邏輯
                      Map<String, List<DocumentSnapshot>> groupedByDate = {};
                      for (var d in filteredDocs) {
                        final data = d.data() as Map<String, dynamic>;
                        String dateStr = '未知日期';
                        if (data['effectiveDateTime'] != null) {
                          DateTime dt = DateTime.parse(
                            data['effectiveDateTime'],
                          ).toLocal();
                          dateStr =
                              '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
                        } else if (data['timestamp'] is Timestamp) {
                          DateTime dt = (data['timestamp'] as Timestamp)
                              .toDate()
                              .toLocal();
                          dateStr =
                              '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
                        }
                        if (!groupedByDate.containsKey(dateStr)) {
                          groupedByDate[dateStr] = [];
                        }
                        groupedByDate[dateStr]!.add(d);
                      }

                      var sortedDates = groupedByDate.keys.toList()
                        ..sort((a, b) => b.compareTo(a));

                      return Column(
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            color: const Color(0xFF121212),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              physics: const AlwaysScrollableScrollPhysics(),
                              child: Row(
                                children: sites.map((site) {
                                  bool isSelected = _selectedSite == site;
                                  return Padding(
                                    padding: const EdgeInsets.only(right: 8.0),
                                    child: ChoiceChip(
                                      label: Text(
                                        site,
                                        style: TextStyle(
                                          color: isSelected
                                              ? Colors.white
                                              : Colors.grey.shade400,
                                          fontWeight: isSelected
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                          fontSize: 13,
                                        ),
                                      ),
                                      selected: isSelected,
                                      selectedColor: Colors.blueAccent,
                                      backgroundColor: const Color(0xFF2C2C2C),
                                      showCheckmark: false,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      onSelected: (bool selected) {
                                        setState(() {
                                          _selectedSite = site;
                                        });
                                      },
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                          Expanded(
                            child: filteredDocs.isEmpty
                                ? const Center(
                                    child: Text(
                                      '此部位無歷史紀錄',
                                      style: TextStyle(
                                        color: Colors.white70,
                                        fontSize: 15,
                                      ),
                                    ),
                                  )
                                : ListView.builder(
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    padding: const EdgeInsets.only(
                                      left: 10,
                                      right: 10,
                                      top: 4,
                                      bottom: 100,
                                    ),
                                    itemCount: sortedDates.length,
                                    itemBuilder: (context, index) {
                                      String dateKey = sortedDates[index];
                                      var dayDocs = groupedByDate[dateKey]!;
                                      dayDocs.sort((a, b) {
                                        String timeA =
                                            (a.data()
                                                as Map)['effectiveDateTime'] ??
                                            '';
                                        String timeB =
                                            (b.data()
                                                as Map)['effectiveDateTime'] ??
                                            '';
                                        return timeB.compareTo(timeA);
                                      });

                                      return Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 20,
                                              bottom: 12,
                                              left: 4,
                                            ),
                                            child: Row(
                                              children: [
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 12,
                                                        vertical: 6,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: Colors.blueAccent
                                                        .withValues(
                                                          alpha: 0.15,
                                                        ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          20,
                                                        ),
                                                    border: Border.all(
                                                      color: Colors.blueAccent
                                                          .withValues(
                                                            alpha: 0.5,
                                                          ),
                                                    ),
                                                  ),
                                                  child: Row(
                                                    children: [
                                                      const Icon(
                                                        Icons.calendar_month,
                                                        size: 16,
                                                        color:
                                                            Colors.blueAccent,
                                                      ),
                                                      const SizedBox(width: 6),
                                                      Text(
                                                        dateKey,
                                                        style: const TextStyle(
                                                          fontSize: 15,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color:
                                                              Colors.blueAccent,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Container(
                                                    height: 1,
                                                    color: Colors.blueAccent
                                                        .withValues(alpha: 0.2),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          ...dayDocs.map(
                                            (doc) => DualModalOverlayCard(
                                              docId: doc.id,
                                              data:
                                                  doc.data()
                                                      as Map<String, dynamic>,
                                              onDelete: () {
                                                showDialog(
                                                  context: context,
                                                  builder: (ctx) => AlertDialog(
                                                    title: const Text(
                                                      '⚠️️ 刪除紀錄',
                                                      style: TextStyle(
                                                        fontSize: 18,
                                                      ),
                                                    ),
                                                    content: const Text(
                                                      '確定刪除紀錄？',
                                                      style: TextStyle(
                                                        fontSize: 15,
                                                      ),
                                                    ),
                                                    actions: [
                                                      TextButton(
                                                        onPressed: () =>
                                                            Navigator.pop(ctx),
                                                        child: const Text('取消'),
                                                      ),
                                                      ElevatedButton(
                                                        style:
                                                            ElevatedButton.styleFrom(
                                                              backgroundColor:
                                                                  Colors
                                                                      .redAccent,
                                                            ),
                                                        onPressed: () async {
                                                          Navigator.pop(ctx);
                                                          final messenger =
                                                              ScaffoldMessenger.of(
                                                                context,
                                                              );
                                                          try {
                                                            await _deleteStoredMediaFromBundle(
                                                              doc.data()
                                                                  as Map<
                                                                    String,
                                                                    dynamic
                                                                  >,
                                                            );
                                                            await FirebaseFirestore
                                                                .instance
                                                                .collection(
                                                                  'patients',
                                                                )
                                                                .doc(
                                                                  widget
                                                                      .patientDocId,
                                                                )
                                                                .collection(
                                                                  'observations',
                                                                )
                                                                .doc(doc.id)
                                                                .delete();
                                                          } catch (error) {
                                                            if (mounted) {
                                                              messenger.showSnackBar(
                                                                SnackBar(
                                                                  content: Text(
                                                                    '刪除紀錄失敗: $error',
                                                                  ),
                                                                  backgroundColor:
                                                                      Colors
                                                                          .redAccent,
                                                                ),
                                                              );
                                                            }
                                                          }
                                                        },
                                                        child: const Text(
                                                          '刪除',
                                                          style: TextStyle(
                                                            color: Colors.white,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'export_history_json',
            onPressed: _exportHistoryJson,
            icon: const Icon(Icons.data_object, size: 20),
            label: const Text('匯出歷史 JSON', style: TextStyle(fontSize: 15)),
            backgroundColor: Colors.indigoAccent,
            foregroundColor: Colors.white,
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'add_record',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => BodyPartSelectionPage(
                  patient: widget.patient,
                  patientDocId: widget.patientDocId,
                ),
              ),
            ),
            icon: const Icon(Icons.camera_alt, size: 20),
            label: const Text('新增紀錄', style: TextStyle(fontSize: 15)),
            backgroundColor: Colors.blueAccent,
            foregroundColor: Colors.white,
          ),
        ],
      ),
    );
  }

  Widget _infoItem(IconData icon, String label, String value) => Column(
    children: [
      Icon(icon, color: Colors.grey, size: 20),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
      Text(
        value,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 14,
        ),
      ),
    ],
  );
}

// =======================================================
// === 拍攝流程：全螢幕引導精靈 ===
// =======================================================
class WoundCaptureWizardPage extends StatefulWidget {
  final Patient patient;
  final String partName;
  final WoundCameraService? cameraService;
  final Future<String> Function()? resolveUserUid;
  const WoundCaptureWizardPage({
    super.key,
    required this.patient,
    required this.partName,
    this.cameraService,
    this.resolveUserUid,
  });
  @override
  State<WoundCaptureWizardPage> createState() => _WoundCaptureWizardPageState();
}

enum ThermalMarkerTarget { wound, reference }

class _WoundCaptureWizardPageState extends State<WoundCaptureWizardPage> {
  int _currentStep = 0;
  WoundCameraService get _cameraService =>
      widget.cameraService ?? sensorLocator.woundCamera;
  final TemperatureSensorService _tempSensorService =
      sensorLocator.temperatureSensor;

  Uint8List? rgbBytes;
  Uint8List? thermalBytes;
  ThermalFrame? _thermalFrame;
  bool _isCapturing = false;
  String _captureStatus = '';

  Offset _woundPoint = const Offset(0.5, 0.5);
  Offset _refPoint = const Offset(0.2, 0.8);
  ThermalMarkerTarget _selectedMarker = ThermalMarkerTarget.wound;
  double _woundTemp = 38.2;
  double _referenceTemp = 35.8;
  DateTime _selectedCaptureTime = DateTime.now();

  final WoundFeatureData featureData = WoundFeatureData();

  Future<void> _pickDateTime() async {
    final DateTime? date = await showDatePicker(
      context: context,
      initialDate: _selectedCaptureTime,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (date != null && mounted) {
      final TimeOfDay? time = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(_selectedCaptureTime),
      );
      if (time != null) {
        setState(() {
          _selectedCaptureTime = DateTime(
            date.year,
            date.month,
            date.day,
            time.hour,
            time.minute,
          );
        });
      }
    }
  }

  Future<void> _capturePair() async {
    if (_isCapturing) return;
    setState(() {
      _isCapturing = true;
      _captureStatus = '正在驗證匿名登入...';
    });
    try {
      final uid = await (widget.resolveUserUid ?? _ensureAnonymousUid)()
          .timeout(const Duration(seconds: 20));
      if (uid.isEmpty) {
        throw StateError('Anonymous sign-in returned an empty UID.');
      }
      if (mounted) {
        setState(() => _captureStatus = '請一次選取 RGB 與 Thermal 兩張影像...');
      }
      final capture = await _cameraService.capturePair();
      if (capture == null || !mounted) return;
      setState(() {
        rgbBytes = capture.rgbBytes;
        _thermalFrame = capture.thermalFrame;
        thermalBytes = capture.thermalFrame.previewBytes;
        _selectedCaptureTime = capture.captureTime;
        _woundTemp = capture.thermalFrame.temperatureAt(_woundPoint);
        _referenceTemp = capture.thermalFrame.temperatureAt(_refPoint);
      });
    } catch (error) {
      debugPrint('影像擷取失敗: $error');
      if (mounted) {
        final message = _isAbortError(error)
            ? '圖片選取已取消，請重新選取 RGB 與 Thermal 影像。'
            : error is FormatException
            ? '請一次選取兩張影像：先選 RGB，再選 Thermal。'
            : error is FirebaseAuthException ||
                  error is StateError ||
                  error is TimeoutException
            ? '匿名登入失敗，請確認 Firebase Console 已啟用 Anonymous Auth。'
            : '影像擷取失敗：$error';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCapturing = false;
          _captureStatus = '';
        });
      }
    }
  }

  void _placeSelectedMarker(Offset normalizedPosition) {
    final thermalFrame = _thermalFrame;
    if (thermalFrame == null) return;

    final position = Offset(
      normalizedPosition.dx.clamp(0.08, 0.92).toDouble(),
      normalizedPosition.dy.clamp(0.08, 0.92).toDouble(),
    );
    setState(() {
      if (_selectedMarker == ThermalMarkerTarget.wound) {
        _woundPoint = position;
        _woundTemp = thermalFrame.temperatureAt(position);
      } else {
        _refPoint = position;
        _referenceTemp = thermalFrame.temperatureAt(position);
      }
    });
  }

  Widget _buildThermalMarker({
    required Offset position,
    required BoxConstraints constraints,
    required Color color,
    required IconData icon,
  }) {
    const double markerSize = 44.0;
    return Positioned(
      left: position.dx * constraints.maxWidth - markerSize / 2,
      top: position.dy * constraints.maxHeight - markerSize / 2,
      child: IgnorePointer(
        child: SizedBox(
          width: markerSize,
          height: markerSize,
          child: Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.3),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.5),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                ),
                Icon(icon, color: color, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '標記部位：${widget.partName}',
          style: const TextStyle(fontSize: 18),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 800),
            width: double.infinity,
            height: double.infinity,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  color: const Color(0xFF1E1E1E),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildStepIcon(0, Icons.camera_alt, '1. 光學'),
                      const Icon(
                        Icons.arrow_forward_ios,
                        color: Colors.grey,
                        size: 12,
                      ),
                      _buildStepIcon(1, Icons.thermostat, '2. 熱像與ΔT'),
                      const Icon(
                        Icons.arrow_forward_ios,
                        color: Colors.grey,
                        size: 12,
                      ),
                      _buildStepIcon(2, Icons.assignment, '3. 評估'),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(20.0),
                    child: _buildCurrentStepContent(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStepIcon(int stepIndex, IconData icon, String label) {
    bool isActive = _currentStep == stepIndex;
    bool isPast = _currentStep > stepIndex;
    Color color = isActive
        ? Colors.blueAccent
        : (isPast ? Colors.green : Colors.grey);
    return Column(
      children: [
        CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.2),
          radius: 20,
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildCurrentStepContent() {
    if (_currentStep == 0) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 20),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '實際拍攝時間 (支援回溯補登)',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_selectedCaptureTime.year}-${_selectedCaptureTime.month.toString().padLeft(2, '0')}-${_selectedCaptureTime.day.toString().padLeft(2, '0')} ${_selectedCaptureTime.hour.toString().padLeft(2, '0')}:${_selectedCaptureTime.minute.toString().padLeft(2, '0')}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: Colors.blueAccent,
                      ),
                    ),
                  ],
                ),
                TextButton.icon(
                  onPressed: _pickDateTime,
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('修改'),
                ),
              ],
            ),
          ),
          const Text(
            '擷取 RGB 與 Thermal 影像',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            '相簿示範模式會依序選取兩張影像；相機服務可用一次擷取回傳同步影像配對。',
            style: TextStyle(color: Colors.grey, fontSize: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          if (rgbBytes != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                rgbBytes!,
                width: double.infinity,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.low,
              ),
            ),
          if (rgbBytes == null)
            AspectRatio(
              aspectRatio: 4 / 3,
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blueAccent, width: 2),
                ),
                child: const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.camera_alt, size: 50, color: Colors.blueAccent),
                    SizedBox(height: 8),
                    Text(
                      '尚未擷取影像',
                      style: TextStyle(fontSize: 16, color: Colors.blueAccent),
                    ),
                  ],
                ),
              ),
            ),
          if (thermalBytes != null) ...[
            const SizedBox(height: 8),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.thermostat,
                  color: Colors.deepOrangeAccent,
                  size: 18,
                ),
                SizedBox(width: 6),
                Text(
                  'Thermal 影像已就緒',
                  style: TextStyle(color: Colors.deepOrangeAccent),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          const Text(
            '相簿示範：請在同一次選取中依序選 RGB 與 Thermal 兩張影像。',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: _isCapturing ? null : _capturePair,
              icon: _isCapturing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.camera_alt),
              label: Text(_isCapturing ? _captureStatus : '擷取 RGB + Thermal'),
            ),
          ),
          const SizedBox(height: 12),
          if (rgbBytes != null && thermalBytes != null)
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: () => setState(() => _currentStep = 1),
                child: const Text('下一步'),
              ),
            ),
        ],
      );
    } else if (_currentStep == 1) {
      double deltaT = _woundTemp - _referenceTemp;
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            '熱影像採集與 ΔT 溫差測量',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            '選擇標記，再點擊熱影像放置位置',
            style: TextStyle(
              color: Colors.lightBlueAccent,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 14),
          SegmentedButton<ThermalMarkerTarget>(
            segments: const [
              ButtonSegment(
                value: ThermalMarkerTarget.wound,
                label: Text('傷口點'),
                icon: Icon(Icons.gps_fixed),
              ),
              ButtonSegment(
                value: ThermalMarkerTarget.reference,
                label: Text('對照點'),
                icon: Icon(Icons.adjust),
              ),
            ],
            selected: {_selectedMarker},
            onSelectionChanged: (selection) =>
                setState(() => _selectedMarker = selection.first),
          ),
          const SizedBox(height: 14),

          if (thermalBytes != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Stack(
                      children: [
                        Image.memory(
                          thermalBytes!,
                          width: constraints.maxWidth,
                          height: constraints.maxHeight,
                          fit: BoxFit.fill,
                          filterQuality: FilterQuality.low,
                        ),
                        Positioned.fill(
                          child: GestureDetector(
                            key: const ValueKey('thermal-image-canvas'),
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (details) => _placeSelectedMarker(
                              Offset(
                                details.localPosition.dx / constraints.maxWidth,
                                details.localPosition.dy /
                                    constraints.maxHeight,
                              ),
                            ),
                          ),
                        ),
                        _buildThermalMarker(
                          position: _refPoint,
                          constraints: constraints,
                          color: Colors.blueAccent,
                          icon: Icons.adjust,
                        ),
                        _buildThermalMarker(
                          position: _woundPoint,
                          constraints: constraints,
                          color: Colors.redAccent,
                          icon: Icons.gps_fixed,
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  final obs = await _tempSensorService.captureTemperature(
                    patient: widget.patient,
                    bodySite: widget.partName,
                    captureTime: _selectedCaptureTime,
                  );
                  if (obs != null && mounted) {
                    setState(() {
                      _woundTemp = obs.temperature;
                    });
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '✅ Pixel 溫度感測成功: $_woundTemp°C',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        backgroundColor: Colors.teal,
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.sensors, size: 20),
                label: const Text('使用 Pixel 溫度感測器量測'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal.shade700,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: deltaT >= 2.0 ? Colors.redAccent : Colors.greenAccent,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Text(
                    '🔴 傷口: $_woundTemp°C',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    '🔵 對照: $_referenceTemp°C',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  Text(
                    'ΔT: ${deltaT >= 0 ? "+" : ""}${deltaT.toStringAsFixed(1)}°C',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: deltaT >= 2.0
                          ? Colors.redAccent
                          : Colors.greenAccent,
                    ),
                  ),
                ],
              ),
            ),
          ],

          if (thermalBytes == null)
            SizedBox(
              width: double.infinity,
              height: 56,
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _currentStep = 0),
                icon: const Icon(Icons.arrow_back),
                label: const Text('返回擷取 RGB + Thermal'),
              ),
            ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() => _currentStep = 0),
                  child: const Text('上一步'),
                ),
              ),
              if (thermalBytes != null) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => setState(() => _currentStep = 2),
                    child: const Text('下一步'),
                  ),
                ),
              ],
            ],
          ),
        ],
      );
    } else {
      // 🌟 核心更新：完全對應 NPUAP 2019 壓傷分級標準的介面
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '📝 臨床專業特徵評估',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),

          const Text(
            '壓傷分期 (PU Stage)',
            style: TextStyle(fontSize: 14, color: Colors.cyanAccent),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2C),
              borderRadius: BorderRadius.circular(8),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: featureData.stage,
                isExpanded: true,
                style: const TextStyle(fontSize: 14, color: Colors.white),
                items:
                    [
                          '第一期 (Stage 1) - 完整皮膚/指壓不白',
                          '第二期 (Stage 2) - 部分皮層/粉紅傷口/血清水泡',
                          '第三期 (Stage 3) - 全層缺損/見脂肪與肉芽',
                          '第四期 (Stage 4) - 暴露骨頭/肌肉/筋膜等深層結構',
                          '無法分期 (Unstageable) - 被焦痂/腐肉完全遮蔽',
                          '深部組織損傷 (DTPI) - 紫/栗色變色或血性水泡',
                        ]
                        .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                        .toList(),
                onChanged: (val) => setState(() => featureData.stage = val!),
              ),
            ),
          ),
          const SizedBox(height: 16),

          const Text(
            '主要組織型態 (Tissue Type)',
            style: TextStyle(fontSize: 14, color: Colors.lightGreenAccent),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF2C2C2C),
              borderRadius: BorderRadius.circular(8),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: featureData.tissueType,
                isExpanded: true,
                style: const TextStyle(fontSize: 14, color: Colors.white),
                items:
                    [
                          '完整無破損 (Intact skin)',
                          '紅/粉紅具活性組織 (無腐肉)',
                          '黃色脂肪層 (Adipose visible)',
                          '紅色肉芽組織 (Granulation)',
                          '深層結構 (骨頭/肌肉/肌腱/筋膜)',
                          '黃/褐/灰/綠色腐肉 (Slough)',
                          '黑/褐/棕色乾燥焦痂 (Eschar)',
                          '深紫/栗色變色 (Purple/Maroon)',
                          '血清性水泡 (Serum-filled blister)',
                          '血性水泡 (Blood-filled blister)',
                        ]
                        .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                        .toList(),
                onChanged: (val) =>
                    setState(() => featureData.tissueType = val!),
              ),
            ),
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '滲液量 (Exudate)',
                      style: TextStyle(fontSize: 14, color: Colors.amberAccent),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2C2C2C),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: featureData.exudateAmount,
                          isExpanded: true,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.white,
                          ),
                          items:
                              [
                                    '無 (None)',
                                    '少量 (Scant)',
                                    '中量 (Moderate)',
                                    '大量 (Heavy)',
                                  ]
                                  .map(
                                    (v) => DropdownMenuItem(
                                      value: v,
                                      child: Text(v),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (val) =>
                              setState(() => featureData.exudateAmount = val!),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '特殊邊緣與觸感',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.orangeAccent,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2C2C2C),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: featureData.otherFeatures,
                          isExpanded: true,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white,
                          ), // 字體稍微縮小以防破版
                          items:
                              [
                                    '無明顯異常 (None)',
                                    '邊緣內捲 (Epibole)',
                                    '潛行與隧道 (Undermining)',
                                    '觸感軟爛/異常 (Mushy/Boggy)',
                                    '穩定乾燥焦痂 (不可清創)',
                                  ]
                                  .map(
                                    (v) => DropdownMenuItem(
                                      value: v,
                                      child: Text(
                                        v,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (val) =>
                              setState(() => featureData.otherFeatures = val!),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 32),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() => _currentStep = 1),
                  child: const Text('上一步'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    final record = WoundPhotoRecord(
                      rgbBytes: rgbBytes!,
                      thermalBytes: thermalBytes!,
                      features: featureData,
                      woundTemp: _woundTemp,
                      referenceTemp: _referenceTemp,
                      captureTime: _selectedCaptureTime,
                    );
                    Navigator.pop(context, record);
                  },
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('完成並暫存'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }
  }
}

// =======================================================
// === 第三頁：部位選擇與上傳 ===
// =======================================================
class BodyPartSelectionPage extends StatefulWidget {
  final Patient patient;
  final String patientDocId;
  const BodyPartSelectionPage({
    super.key,
    required this.patient,
    required this.patientDocId,
  });
  @override
  State<BodyPartSelectionPage> createState() => _BodyPartSelectionPageState();
}

class _BodyPartSelectionPageState extends State<BodyPartSelectionPage> {
  bool isBackView = true;
  final Map<String, WoundPhotoRecord> _capturedWounds = {};
  late Stream<QuerySnapshot> _woundsStream;

  @override
  void initState() {
    super.initState();
    _woundsStream = FirebaseFirestore.instance
        .collection('patients')
        .doc(widget.patientDocId)
        .collection('observations')
        .snapshots();
  }

  Future<void> _exportFHIRJson() async {
    List<Map<String, dynamic>> exportList = [];
    String dialogTitle = '';
    if (_capturedWounds.isEmpty) {
      try {
        final querySnapshot = await FirebaseFirestore.instance
            .collection('patients')
            .doc(widget.patientDocId)
            .collection('observations')
            .get();
        if (querySnapshot.docs.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  '⚠️ 目前無暫存影像，且資料庫無歷史紀錄',
                  style: TextStyle(fontSize: 15),
                ),
                backgroundColor: Colors.orange,
              ),
            );
          }
          return;
        }
        dynamic sanitize(dynamic item) {
          if (item is Timestamp) return item.toDate().toUtc().toIso8601String();
          if (item is Map) {
            Map<String, dynamic> clean = {};
            item.forEach((key, value) {
              if (key == 'timestamp') return;
              clean[key.toString()] = sanitize(value);
            });
            return clean;
          }
          if (item is List) return item.map((e) => sanitize(e)).toList();
          return item;
        }

        for (var doc in querySnapshot.docs) {
          exportList.add(sanitize(doc.data()));
        }
        dialogTitle = '匯出 FHIR JSON (全部歷史紀錄)';
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('歷史紀錄讀取失敗: $e'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
        return;
      }
    } else {
      for (var entry in _capturedWounds.entries) {
        String partName = entry.key;
        WoundPhotoRecord record = entry.value;

        final fhirObservation = FhirWoundObservation(
          subject: widget.patient,
          bodySite: partName,
          bradenScore: widget.patient.bradenScore,
          features: record.features,
          woundTemp: record.woundTemp,
          referenceTemp: record.referenceTemp,
          captureTime: record.captureTime,
        );
        final rgbMedia = FhirMedia(
          subject: widget.patient,
          base64Data: base64Encode(record.rgbBytes),
          title: 'RGB Optical Image',
          bodySite: partName,
          captureTime: record.captureTime,
        );
        final thermalMedia = FhirMedia(
          subject: widget.patient,
          base64Data: base64Encode(record.thermalBytes),
          title: 'Thermal Infrared Image',
          bodySite: partName,
          captureTime: record.captureTime,
        );
        final tempObservation = FhirTemperatureObservation(
          subject: widget.patient,
          temperature: record.woundTemp,
          bodySite: partName,
          captureTime: record.captureTime,
        );
        exportList.add({
          "resourceType": "Bundle",
          "type": "collection",
          "entry": [
            {"resource": fhirObservation.toJson()},
            {"resource": tempObservation.toJson()},
            {"resource": rgbMedia.toJson()},
            {"resource": thermalMedia.toJson()},
          ],
        });
      }
      dialogTitle = '匯出 FHIR JSON (本次暫存紀錄)';
    }
    JsonEncoder encoder = const JsonEncoder.withIndent('  ');
    String jsonString = encoder.convert(exportList);

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.data_object, color: Colors.blueAccent),
            const SizedBox(width: 8),
            Text(dialogTitle, style: const TextStyle(fontSize: 16)),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                jsonString,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Colors.greenAccent,
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('關閉', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: jsonString));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      '✅ JSON 已複製到剪貼簿！可直接貼上存檔',
                      style: TextStyle(fontSize: 14),
                    ),
                    backgroundColor: Colors.green,
                  ),
                );
                Navigator.pop(context);
              }
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('複製全部'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
          ),
        ],
      ),
    );
  }

  Future<void> _uploadAllToHospitalSystem() async {
    if (_capturedWounds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ 尚未拍攝任何部位影像', style: TextStyle(fontSize: 15)),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final uid = await _ensureAnonymousUid();
      final firestore = FirebaseFirestore.instance;
      for (var entry in _capturedWounds.entries) {
        String partName = entry.key;
        WoundPhotoRecord record = entry.value;
        final uploadId = DateTime.now().microsecondsSinceEpoch.toString();
        final storageDirectory = patientImageStorageDirectory(
          uid: uid,
          patientDocId: widget.patientDocId,
          uploadId: uploadId,
        );
        final rgbReference = FirebaseStorage.instance.ref().child(
          '$storageDirectory/rgb.jpg',
        );
        final thermalReference = FirebaseStorage.instance.ref().child(
          '$storageDirectory/thermal.jpg',
        );
        final uploadedReferences = <Reference>[];

        try {
          await rgbReference.putData(
            record.rgbBytes,
            SettableMetadata(
              contentType: 'image/jpeg',
              customMetadata: {'bodySite': partName, 'imageType': 'rgb'},
            ),
          );
          uploadedReferences.add(rgbReference);
          await thermalReference.putData(
            record.thermalBytes,
            SettableMetadata(
              contentType: 'image/jpeg',
              customMetadata: {'bodySite': partName, 'imageType': 'thermal'},
            ),
          );
          uploadedReferences.add(thermalReference);
          final imageUrls = await Future.wait([
            rgbReference.getDownloadURL(),
            thermalReference.getDownloadURL(),
          ]);

          final fhirObservation = FhirWoundObservation(
            subject: widget.patient,
            bodySite: partName,
            bradenScore: widget.patient.bradenScore,
            features: record.features,
            woundTemp: record.woundTemp,
            referenceTemp: record.referenceTemp,
            captureTime: record.captureTime,
          );
          final rgbMedia = FhirMedia(
            subject: widget.patient,
            url: imageUrls[0],
            title: 'RGB Optical Image',
            bodySite: partName,
            captureTime: record.captureTime,
          );
          final thermalMedia = FhirMedia(
            subject: widget.patient,
            url: imageUrls[1],
            title: 'Thermal Infrared Image',
            bodySite: partName,
            captureTime: record.captureTime,
          );
          final tempObservation = FhirTemperatureObservation(
            subject: widget.patient,
            temperature: record.woundTemp,
            bodySite: partName,
            captureTime: record.captureTime,
          );
          Map<String, dynamic> bundleJson = {
            "resourceType": "Bundle",
            "type": "collection",
            "timestamp": FieldValue.serverTimestamp(),
            "effectiveDateTime": record.captureTime.toUtc().toIso8601String(),
            "bodySite": {"text": partName},
            "entry": [
              {"resource": fhirObservation.toJson()},
              {"resource": tempObservation.toJson()},
              {"resource": rgbMedia.toJson()},
              {"resource": thermalMedia.toJson()},
            ],
          };

          await firestore
              .collection('patients')
              .doc(widget.patientDocId)
              .collection('observations')
              .add(bundleJson)
              .timeout(const Duration(seconds: 10));
        } catch (_) {
          for (final reference in uploadedReferences) {
            try {
              await reference.delete();
            } on FirebaseException catch (cleanupError) {
              if (cleanupError.code != 'object-not-found') {
                debugPrint('無法清理未完成上傳的影像: $cleanupError');
              }
            }
          }
          rethrow;
        }
      }
      if (!mounted) return;
      Navigator.pop(context);
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🎉 FHIR 病歷上傳成功！', style: TextStyle(fontSize: 15)),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      final errorMessage = e is FirebaseAuthException
          ? '匿名登入失敗，請確認 Firebase Console 已啟用 Anonymous Auth。'
          : _isAbortError(e)
          ? '瀏覽器已中止上傳，請保持頁面開啟後重試。'
          : e is FirebaseException && e.code == 'quota-exceeded'
          ? 'Firebase Storage 容量配額已滿。請清理舊檔或升級 Firebase 方案後重試。'
          : '上傳失敗: $e';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Widget _viewButton(String label, IconData icon, bool viewState) =>
      ElevatedButton.icon(
        onPressed: () => setState(() => isBackView = viewState),
        icon: Icon(icon, size: 18),
        label: Text(label, style: const TextStyle(fontSize: 14)),
        style: ElevatedButton.styleFrom(
          backgroundColor: isBackView == viewState
              ? Colors.blueAccent
              : const Color(0xFF2C2C2C),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        ),
      );

  List<Widget> _buildBackDots(BuildContext context, Set<String> existing) => [
    _point(context, 0.73, 0.12, '後腦勺 (Back of Head)', existing),
    _point(context, 0.58, 0.23, '左側肩胛骨 (L Shoulder Blade)', existing),
    _point(context, 0.88, 0.23, '右側肩胛骨 (R Shoulder Blade)', existing),
    _point(context, 0.46, 0.38, '左側肘部 (L Elbow)', existing),
    _point(context, 0.98, 0.38, '右側肘部 (R Elbow)', existing),
    _point(context, 0.73, 0.40, '脊椎 (Spine)', existing),
    _point(context, 0.73, 0.50, '薦骨/尾椎 (Sacrum)', existing),
    _point(context, 0.65, 0.55, '左側坐骨脊 (L Ischial Tuberosity)', existing),
    _point(context, 0.81, 0.55, '右側坐骨脊 (R Ischial Tuberosity)', existing),
    _point(context, 0.68, 0.89, '左側足跟 (L Heel)', existing),
    _point(context, 0.78, 0.89, '右側足跟 (R Heel)', existing),
  ];

  List<Widget> _buildFrontDots(BuildContext context, Set<String> existing) => [
    _point(context, 0.30, 0.16, '右側耳部 (R Ear)', existing),
    _point(context, 0.47, 0.16, '左側耳部 (L Ear)', existing),
    _point(context, 0.19, 0.25, '右側肩部 (R Shoulder)', existing),
    _point(context, 0.57, 0.25, '左側肩部 (L Shoulder)', existing),
    _point(context, 0.38, 0.34, '胸廓中央 (Chest)', existing),
    _point(context, 0.26, 0.44, '右側髖部 (R Hip)', existing),
    _point(context, 0.50, 0.44, '左側髖部 (L Hip)', existing),
    _point(context, 0.32, 0.66, '右側膝蓋 (R Knee)', existing),
    _point(context, 0.45, 0.66, '左側膝蓋 (L Knee)', existing),
    _point(context, 0.33, 0.87, '右側足趾 (R Toes)', existing),
    _point(context, 0.45, 0.87, '左側足趾 (L Toes)', existing),
  ];

  Widget _point(
    BuildContext context,
    double xPercent,
    double yPercent,
    String name,
    Set<String> existing,
  ) {
    final messenger = ScaffoldMessenger.of(context);
    bool isJustCaptured = _capturedWounds.containsKey(name);
    bool isHistoricallyRecorded = existing.contains(name);
    Color dotColor;
    IconData dotIcon;

    if (isJustCaptured) {
      dotColor = Colors.greenAccent.withValues(alpha: 0.9);
      dotIcon = Icons.check;
    } else if (isHistoricallyRecorded) {
      dotColor = Colors.amberAccent.withValues(alpha: 0.9);
      dotIcon = Icons.history;
    } else {
      dotColor = Colors.redAccent.withValues(alpha: 0.85);
      dotIcon = Icons.add;
    }

    return Align(
      alignment: Alignment((xPercent * 2) - 1, (yPercent * 2) - 1),
      child: GestureDetector(
        onTap: () async {
          if (isJustCaptured) {
            messenger.showSnackBar(
              const SnackBar(
                content: Text(
                  '✅ 已在本次暫存清單中，若需重拍請先上傳後再新增',
                  style: TextStyle(fontSize: 14),
                ),
              ),
            );
          } else {
            final WoundPhotoRecord? result = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => WoundCaptureWizardPage(
                  patient: widget.patient,
                  partName: name,
                ),
              ),
            );
            if (result != null && mounted) {
              setState(() {
                _capturedWounds[name] = result;
              });
              messenger.showSnackBar(
                const SnackBar(
                  content: Text(
                    '✅ 評估已暫存，請繼續標記或點擊上傳',
                    style: TextStyle(fontSize: 14),
                  ),
                  backgroundColor: Colors.green,
                ),
              );
            }
          }
        },
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4)],
          ),
          child: Icon(dotIcon, size: 20, color: Colors.white),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    bool isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${widget.patient.name} - 部位選擇',
          style: const TextStyle(fontSize: 18),
        ),
      ),
      body: SafeArea(
        child: StreamBuilder<QuerySnapshot>(
          stream: _woundsStream,
          builder: (context, snapshot) {
            Set<String> existingWounds = {};
            if (snapshot.hasData) {
              for (var doc in snapshot.data!.docs) {
                var data = doc.data() as Map<String, dynamic>;
                if (data['bodySite'] != null &&
                    data['bodySite']['text'] != null) {
                  existingWounds.add(data['bodySite']['text']);
                }
              }
            }

            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _viewButton('背面觀', Icons.person_search, true),
                      const SizedBox(width: 16),
                      _viewButton('正面觀', Icons.person, false),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '🔴 未拍攝   🟡 歷史需追蹤   🟢 本次已拍攝',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),

                  LayoutBuilder(
                    builder: (context, constraints) {
                      double maxWidth = constraints.maxWidth;
                      double containerWidth;
                      if (maxWidth > 600) {
                        double screenHeight = MediaQuery.of(
                          context,
                        ).size.height;
                        containerWidth = (screenHeight * 0.65) * (350 / 600);
                      } else {
                        containerWidth = isLandscape
                            ? 180
                            : (maxWidth > 380 ? 380 : maxWidth * 0.92);
                      }
                      double containerHeight = containerWidth * (600 / 350);

                      return Center(
                        child: Container(
                          width: containerWidth,
                          height: containerHeight,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E1E1E),
                            border: Border.all(color: Colors.grey.shade800),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            clipBehavior: Clip.none,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: Image.asset(
                                  isBackView
                                      ? 'assets/images/body_back.png.jpg'
                                      : 'assets/images/body_front.png.jpg',
                                  width: containerWidth,
                                  height: containerHeight,
                                  fit: BoxFit.fill,
                                  errorBuilder: (c, e, s) =>
                                      const Center(child: Text("找不到圖片")),
                                ),
                              ),
                              if (isBackView)
                                ..._buildBackDots(context, existingWounds),
                              if (!isBackView)
                                ..._buildFrontDots(context, existingWounds),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 150),
                ],
              ),
            );
          },
        ),
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'export_json',
            onPressed: _exportFHIRJson,
            icon: const Icon(Icons.data_object, size: 20),
            label: const Text('匯出 JSON', style: TextStyle(fontSize: 15)),
            backgroundColor: Colors.indigoAccent,
            foregroundColor: Colors.white,
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'upload_db',
            onPressed: _uploadAllToHospitalSystem,
            icon: const Icon(Icons.cloud_upload, size: 20),
            label: const Text('上傳 FHIR 病歷', style: TextStyle(fontSize: 15)),
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
          ),
        ],
      ),
    );
  }
}
