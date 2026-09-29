import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const WoundCareApp());
}

class WoundCareApp extends StatelessWidget {
  const WoundCareApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '傷口預警系統',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF1E1E1E), foregroundColor: Colors.white, elevation: 0),
        cardColor: const Color(0xFF1E1E1E),
        dialogBackgroundColor: const Color(0xFF1E1E1E),
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent, brightness: Brightness.dark),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)
          )
        ),
      ),
      home: const PatientListPage(),
    );
  }
}

// =======================================================
// === 1. 熱像儀硬體介接架構 ===
// =======================================================
abstract class ThermalCameraService {
  Future<Map<String, dynamic>?> captureThermalData();
}

class MockThermalCamera implements ThermalCameraService {
  final ImagePicker _picker = ImagePicker();
  @override
  Future<Map<String, dynamic>?> captureThermalData() async {
    final XFile? photo = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 60, maxWidth: 600, maxHeight: 600);
    if (photo == null) return null;
    final bytes = await photo.readAsBytes();
    return {
      'imageBytes': bytes,
      'woundTemp': 38.2,
      'referenceTemp': 35.8,
    };
  }
}

class NativeFlirCamera implements ThermalCameraService {
  static const platform = MethodChannel('com.woundcare.app/thermal_channel');
  @override
  Future<Map<String, dynamic>?> captureThermalData() async {
    try {
      final Map<dynamic, dynamic> result = await platform.invokeMethod('startFlirCamera');
      return {
        'imageBytes': result['imageBytes'] as Uint8List,
        'woundTemp': result['woundTemp'] as double,
        'referenceTemp': result['referenceTemp'] as double,
      };
    } catch (e) {
      debugPrint("呼叫真實熱像儀失敗: $e");
      return null;
    }
  }
}

// =======================================================
// === 2. 核心資料模型 (符合國際 HL7 FHIR R4 格式) ===
// =======================================================
class Patient {
  final String bedNumber; final String name; final String id; final String gender; final int age; final double bradenScore;
  Patient({required this.bedNumber, required this.name, required this.id, required this.gender, required this.age, required this.bradenScore});
  Map<String, dynamic> toJson() => {'bedNumber': bedNumber, 'name': name, 'id': id, 'gender': gender, 'age': age, 'bradenScore': bradenScore};
  factory Patient.fromJson(Map<String, dynamic> json) => Patient(
    bedNumber: json['bedNumber'] ?? '',
    name: json['name'] ?? '',
    id: json['id'] ?? '',
    gender: json['gender'] ?? '男',
    age: (json['age'] is num) ? (json['age'] as num).toInt() : int.tryParse(json['age']?.toString() ?? '0') ?? 0,
    bradenScore: (json['bradenScore'] is num) ? (json['bradenScore'] as num).toDouble() : double.tryParse(json['bradenScore']?.toString() ?? '23') ?? 23.0
  );
}

class WoundFeatureData { String exudateAmount = '少量'; String tissueType = '紅色肉芽組織'; }

class WoundPhotoRecord {
  final Uint8List rgbBytes;
  final Uint8List thermalBytes;
  final WoundFeatureData features;
  final double woundTemp;
  final double referenceTemp;
  final DateTime captureTime; // 🌟 支援自訂實際拍攝時間
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

// 🌟 升級版：符合 HL7 FHIR R4 + LOINC 國際醫學代碼的資料模型
class FhirWoundObservation {
  final Patient subject;
  final String bodySite;
  final double bradenScore;
  final WoundFeatureData features;
  final String rgbBase64;
  final String thermalBase64;
  final double woundTemp;
  final double referenceTemp;
  final DateTime captureTime; // 🌟 新增

  FhirWoundObservation({
    required this.subject,
    required this.bodySite,
    required this.bradenScore,
    required this.features,
    required this.rgbBase64,
    required this.thermalBase64,
    required this.woundTemp,
    required this.referenceTemp,
    required this.captureTime,
  });
  
  Map<String, dynamic> toFhirJson() {
    double deltaT = woundTemp - referenceTemp;
    String recordIso = captureTime.toUtc().toIso8601String(); // 🌟 綁定臨床實際時間
    return {
      "resourceType": "Observation",
      "status": "final",
      "category": [
        {
          "coding": [
            {
              "system": "http://terminology.hl7.org/CodeSystem/observation-category",
              "code": "exam",
              "display": "Exam"
            }
          ]
        }
      ],
      "code": {
        "coding": [
          {"system": "http://loinc.org", "code": "39126-8", "display": "Wound assessment panel"} 
        ],
        "text": "熱影像傷口評估報告"
      },
      "subject": {
        "reference": "Patient/${subject.id}",
        "display": subject.name
      },
      "effectiveDateTime": recordIso, // 🌟 寫入設定的時間
      "bodySite": {
        "text": bodySite 
      },
      "component": [
        {
          "code": {"coding": [{"system": "http://loinc.org", "code": "38228-3", "display": "Braden scale total score"}]},
          "valueQuantity": {"value": bradenScore, "system": "http://unitsofmeasure.org", "code": "{score}"}
        },
        {
          "code": {"coding": [{"system": "http://loinc.org", "code": "72290-0", "display": "Exudate amount"}]},
          "valueCodeableConcept": {"text": features.exudateAmount} 
        },
        {
          "code": {"coding": [{"system": "http://loinc.org", "code": "72289-2", "display": "Tissue type in wound bed"}]},
          "valueCodeableConcept": {"text": features.tissueType}
        },
        {
          "code": {"coding": [{"system": "http://loinc.org", "code": "72728-9", "display": "Wound image"}]},
          "valueAttachment": {"contentType": "image/jpeg", "data": rgbBase64, "title": "RGB Optical Image"}
        },
        {
          "code": {"coding": [{"system": "http://loinc.org", "code": "72728-9", "display": "Thermal Image"}]},
          "valueAttachment": {"contentType": "image/jpeg", "data": thermalBase64, "title": "Thermal Infrared Image"}
        },
        {
          "code": {"coding": [{"system": "http://loinc.org", "code": "8310-5", "display": "Body temperature"}]},
          "valueQuantity": {"value": woundTemp, "unit": "Cel", "system": "http://unitsofmeasure.org", "code": "Cel"}
        },
        {
          "code": {"text": "Periwound Reference Temperature"},
          "valueQuantity": {"value": referenceTemp, "unit": "Cel", "system": "http://unitsofmeasure.org", "code": "Cel"}
        },
        {
          "code": {"text": "Temperature Difference (Delta T)"},
          "valueQuantity": {"value": double.parse(deltaT.toStringAsFixed(1)), "unit": "Cel", "system": "http://unitsofmeasure.org", "code": "Cel"}
        }
      ]
    };
  }
}

// =======================================================
// === 第一頁：病患清單 ===
// =======================================================
class PatientListPage extends StatefulWidget { const PatientListPage({super.key}); @override State<PatientListPage> createState() => _PatientListPageState(); }
class _PatientListPageState extends State<PatientListPage> {
  late Stream<QuerySnapshot> _patientsStream;
  String _searchQuery = '';
  @override void initState() { super.initState(); _patientsStream = FirebaseFirestore.instance.collection('patients').snapshots(); }
  
  void _showAddPatientDialog() {
    final bedController = TextEditingController(); final nameController = TextEditingController(); final idController = TextEditingController(); final ageController = TextEditingController(); final scoreController = TextEditingController(); String selectedGender = '男';
    showDialog(context: context, builder: (context) => StatefulBuilder(builder: (context, setDialogState) => AlertDialog(
      title: const Row(children: [Icon(Icons.person_add, color: Colors.blueAccent, size: 24), SizedBox(width: 8), Text('登錄新病患', style: TextStyle(fontSize: 18))]),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: bedController, decoration: const InputDecoration(labelText: '床號 (如 301-A)')),
        TextField(controller: nameController, decoration: const InputDecoration(labelText: '病患姓名')),
        TextField(controller: idController, decoration: const InputDecoration(labelText: '病歷號')),
        Row(children: [
          Expanded(child: TextField(controller: ageController, decoration: const InputDecoration(labelText: '年齡'), keyboardType: TextInputType.number)),
          const SizedBox(width: 16),
          DropdownButton<String>(value: selectedGender, items: ['男', '女'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(), onChanged: (val) => setDialogState(() => selectedGender = val!))
        ]),
        TextField(controller: scoreController, decoration: const InputDecoration(labelText: 'Braden 評分 (6-23)'), keyboardType: TextInputType.number),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        ElevatedButton(onPressed: () async {
          if (nameController.text.isEmpty || idController.text.isEmpty) return;
          final newPatient = Patient(bedNumber: bedController.text, name: nameController.text, id: idController.text, gender: selectedGender, age: int.tryParse(ageController.text) ?? 0, bradenScore: double.tryParse(scoreController.text) ?? 23);
          await FirebaseFirestore.instance.collection('patients').add(newPatient.toJson());
          if (context.mounted) Navigator.pop(context);
        }, child: const Text('確認登錄'))
      ],
    )));
  }
 
  void _confirmDeletePatient(String docId, String patientName) {
    showDialog(context: context, builder: (context) => AlertDialog(
      title: const Text('⚠️ 刪除病患', style: TextStyle(fontSize: 18)),
      content: Text('確定刪除「$patientName」？', style: const TextStyle(fontSize: 15)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent), onPressed: () async { Navigator.pop(context); await FirebaseFirestore.instance.collection('patients').doc(docId).delete(); }, child: const Text('刪除', style: TextStyle(color: Colors.white)))
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('傷口預警管理系統', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
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
                contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none)
              )
            )
          )
        )
      ),
      body: SafeArea(
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 800),
            width: double.infinity, height: double.infinity,
            child: StreamBuilder<QuerySnapshot>(
              stream: _patientsStream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) return const Center(child: Text('目前無病患資料', style: TextStyle(fontSize: 16, color: Colors.grey)));
                var patientList = snapshot.data!.docs.map((doc) => {'docId': doc.id, 'patient': Patient.fromJson(doc.data() as Map<String, dynamic>)}).toList();
                patientList.sort((a, b) => (a['patient'] as Patient).bradenScore.compareTo((b['patient'] as Patient).bradenScore));
                if (_searchQuery.isNotEmpty) {
                  patientList = patientList.where((item) {
                    final p = item['patient'] as Patient;
                    return p.name.contains(_searchQuery) || p.bedNumber.contains(_searchQuery) || p.id.contains(_searchQuery);
                  }).toList();
                }
               
                return ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(left: 12, right: 12, top: 8, bottom: 100),
                  itemCount: patientList.length,
                  itemBuilder: (context, index) {
                    final docId = patientList[index]['docId'] as String;
                    final p = patientList[index]['patient'] as Patient;
                    Color riskColor = p.bradenScore <= 12 ? Colors.redAccent : (p.bradenScore <= 14 ? Colors.orangeAccent : Colors.greenAccent);
                   
                    return Card(
                      elevation: 3, margin: const EdgeInsets.only(bottom: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(color: p.bradenScore <= 12 ? Colors.redAccent.withValues(alpha: 0.6) : Colors.transparent, width: 1.5)
                      ),
                      child: InkWell(
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => PatientHistoryPage(patient: p))),
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Container(
                                width: 54, height: 54,
                                decoration: BoxDecoration(color: Colors.blueGrey.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(10)),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.hotel, color: Colors.blueAccent, size: 20),
                                    const SizedBox(height: 2),
                                    FittedBox(fit: BoxFit.scaleDown, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: Text(p.bedNumber, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueAccent))))
                                  ]
                                )
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
                                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                                            overflow: TextOverflow.ellipsis
                                          )
                                        ),
                                        const SizedBox(width: 6),
                                        Text('${p.gender} / ${p.age}歲', style: const TextStyle(color: Colors.grey, fontSize: 13))
                                      ]
                                    ),
                                    const SizedBox(height: 4),
                                    Text('病歷號: ${p.id}', style: const TextStyle(color: Colors.white70, fontSize: 13), overflow: TextOverflow.ellipsis)
                                  ]
                                )
                              ),
                              const SizedBox(width: 8),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(color: riskColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(12), border: Border.all(color: riskColor.withValues(alpha: 0.6))),
                                    child: Text('Braden: ${p.bradenScore.toInt()}分', style: TextStyle(color: riskColor, fontWeight: FontWeight.bold, fontSize: 12))
                                  ),
                                ]
                              ),
                              IconButton(
                                padding: const EdgeInsets.only(left: 8),
                                constraints: const BoxConstraints(),
                                icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 22),
                                onPressed: () => _confirmDeletePatient(docId, p.name)
                              ),
                            ]
                          )
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
        foregroundColor: Colors.white
      ),
    );
  }
}

// =======================================================
// === 歷史疊加紀錄卡 ===
// =======================================================
class DualModalOverlayCard extends StatefulWidget {
  final String docId; final Map<String, dynamic> data; final VoidCallback onDelete;
  const DualModalOverlayCard({super.key, required this.docId, required this.data, required this.onDelete});
  @override State<DualModalOverlayCard> createState() => _DualModalOverlayCardState();
}
class _DualModalOverlayCardState extends State<DualModalOverlayCard> {
  double _thermalOpacity = 0.5;
  String? _rgbUrl;
  String? _thermalUrl;
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
  
  Future<void> _parseImagesAsync() async {
    setState(() => _isParsing = true);
    await Future.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    try {
      List<dynamic> comps = widget.data['component'] ?? [];
      String rgbBase64 = _extractVal(comps, 'RGB Optical Image', 'Wound image');
      if (rgbBase64.isEmpty && widget.data['media'] != null) rgbBase64 = widget.data['media']['rgb_url'] ?? '';
     
      String thermalBase64 = _extractVal(comps, 'Thermal Infrared Image', 'Thermal Image');
      if (thermalBase64.isEmpty && widget.data['media'] != null) thermalBase64 = widget.data['media']['thermal_url'] ?? '';
      _rgbUrl = _convertToSafeDataUri(rgbBase64);
      _thermalUrl = _convertToSafeDataUri(thermalBase64);
    } catch (e) {
      debugPrint('圖片解析異常: $e');
    } finally {
      if (mounted) setState(() => _isParsing = false);
    }
  }
  
  String? _convertToSafeDataUri(String? dataString) {
    if (dataString == null || dataString.trim().isEmpty) return null;
    String cleanString = dataString.replaceAll('\n', '').replaceAll('\r', '').replaceAll(' ', '');
    if (cleanString.startsWith('http://') || cleanString.startsWith('https://')) return cleanString;
    if (cleanString.startsWith('data:image')) return cleanString;
    cleanString = cleanString.replaceAll('-', '+').replaceAll('_', '/');
    int padding = cleanString.length % 4;
    if (padding != 0) cleanString += '=' * (4 - padding);
    return 'data:image/jpeg;base64,$cleanString';
  }
  
  // 🌟 使用 FHIR 的 effectiveDateTime 或 fallback 到 timestamp
  String _formatDateSafe(Map<String, dynamic> data) {
    if (data['effectiveDateTime'] != null) {
      try {
        DateTime d = DateTime.parse(data['effectiveDateTime']).toLocal();
        return '${d.month.toString().padLeft(2,'0')}/${d.day.toString().padLeft(2,'0')} ${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
      } catch (_) {}
    }
    dynamic t = data['timestamp'];
    if (t == null) return '剛剛記錄';
    if (t is Timestamp) {
      DateTime d = t.toDate();
      return '${d.month.toString().padLeft(2,'0')}/${d.day.toString().padLeft(2,'0')} ${d.hour.toString().padLeft(2,'0')}:${d.minute.toString().padLeft(2,'0')}';
    }
    return t.toString();
  }
 
  String _extractVal(List<dynamic> comps, String txt, [String? loincDisplay]) {
    try {
      for (var c in comps) {
        if (c is Map && c['code'] != null) {
          bool match = false;
          if (c['code']['text'] == txt) match = true;
          if (loincDisplay != null && c['code']['coding'] != null && c['code']['coding'][0]['display'] == loincDisplay) match = true;
          
          if (match) {
            if (c['valueCodeableConcept'] != null) return c['valueCodeableConcept']['text'];
            if (c['valueString'] != null) return c['valueString'];
            if (c['valueAttachment'] != null && c['valueAttachment']['data'] != null) return c['valueAttachment']['data'];
            if (c['valueQuantity'] != null && c['valueQuantity']['value'] != null) return c['valueQuantity']['value'].toString();
          }
        }
      }
    } catch (e) {
      debugPrint('數值提取錯誤: $e');
    }
    return '';
  }
  
  Widget _buildImageProvider(String? url) {
    if (url != null && url.isNotEmpty) {
      return Image.network(
        url, fit: BoxFit.cover, width: double.infinity, gaplessPlayback: true,
        filterQuality: FilterQuality.low,
        errorBuilder: (c, e, s) => const Center(child: Icon(Icons.error, color: Colors.redAccent, size: 36)),
      );
    }
    return const Center(child: Icon(Icons.broken_image, color: Colors.grey, size: 36));
  }
  
  @override
  Widget build(BuildContext context) {
    List<dynamic> comps = widget.data['component'] ?? [];
    String exudate = _extractVal(comps, 'Exudate Amount (滲液量)', 'Exudate amount');
    String tissue = _extractVal(comps, 'Tissue Type (傷口組織)', 'Tissue type in wound bed');
    String woundTempStr = _extractVal(comps, 'Wound Center Temperature', 'Body temperature');
    String deltaTStr = _extractVal(comps, 'Temperature Difference (Delta T)');
   
    double? deltaT = double.tryParse(deltaTStr);
    Color deltaColor = Colors.grey;
    String alertText = '溫差評估';
    if (deltaT != null) {
      if (deltaT >= 2.0) {
        deltaColor = Colors.redAccent;
        alertText = '🔥 顯著發炎 (ΔT +$deltaT°C)';
      } else if (deltaT >= 1.0) {
        deltaColor = Colors.amberAccent;
        alertText = '⚠️ 輕度充血 (ΔT +$deltaT°C)';
      } else if (deltaT >= -1.0) {
        deltaColor = Colors.greenAccent;
        alertText = '✅ 正常範圍 (ΔT $deltaT°C)';
      } else {
        deltaColor = Colors.purpleAccent;
        alertText = '❄️ 缺血壞死 (ΔT $deltaT°C)';
      }
    }
    
    return Card(
      elevation: 4, margin: const EdgeInsets.only(bottom: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.accessibility_new, color: Colors.blueAccent, size: 20),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.data['bodySite']?['text'] ?? '未知部位',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  _formatDateSafe(widget.data), // 🌟 傳入整份 data 進行時間解析
                  style: const TextStyle(color: Colors.grey, fontSize: 11),
                ),
                IconButton(
                  padding: const EdgeInsets.only(left: 8),
                  constraints: const BoxConstraints(),
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 22),
                  onPressed: widget.onDelete,
                ),
              ],
            ),
            const Divider(height: 16, color: Colors.white12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(8)),
              child: Wrap(
                alignment: WrapAlignment.spaceAround,
                runSpacing: 6,
                spacing: 10,
                children: [
                  Text('💧 滲液: ${exudate.isEmpty ? '未評估' : exudate}', style: const TextStyle(fontSize: 12, color: Colors.amberAccent)),
                  Text('🔬 組織: ${tissue.isEmpty ? '未評估' : tissue}', style: const TextStyle(fontSize: 12, color: Colors.lightGreenAccent)),
                  if (woundTempStr.isNotEmpty) Text('🌡️ 傷口: $woundTempStr°C', style: const TextStyle(fontSize: 12, color: Colors.white70)),
                ]
              )
            ),
            if (deltaT != null)
              Container(
                width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 8), margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(color: deltaColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6), border: Border.all(color: deltaColor.withValues(alpha: 0.5))),
                child: Center(child: Text(alertText, style: TextStyle(color: deltaColor, fontWeight: FontWeight.bold, fontSize: 13))),
              ),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                color: Colors.black,
                width: double.infinity,
                child: _isParsing
                  ? const AspectRatio(aspectRatio: 4/3, child: Center(child: CircularProgressIndicator()))
                  : AspectRatio(
                      aspectRatio: 4 / 3,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          _buildImageProvider(_rgbUrl),
                          Positioned.fill(
                            child: Opacity(
                              opacity: _thermalOpacity,
                              child: _buildImageProvider(_thermalUrl)
                            )
                          )
                        ]
                      )
                    )
              )
            ),
            const SizedBox(height: 12),
            Row(children: [
              const Text('光學', style: TextStyle(fontSize: 13, color: Colors.blueAccent, fontWeight: FontWeight.bold)),
              Expanded(
                child: Slider(
                  value: _thermalOpacity,
                  min: 0.0, max: 1.0,
                  activeColor: Colors.deepOrangeAccent, inactiveColor: Colors.blueAccent.withValues(alpha: 0.3),
                  onChanged: (v) => setState(() => _thermalOpacity = v)
                )
              ),
              const Text('透視', style: TextStyle(fontSize: 13, color: Colors.deepOrangeAccent, fontWeight: FontWeight.bold))
            ]),
          ],
        ),
      ),
    );
  }
}

// =======================================================
// === 第二頁：歷史紀錄頁 (🌟 時間軸 Timeline 分組版) ===
// =======================================================
class PatientHistoryPage extends StatefulWidget {
  final Patient patient;
  const PatientHistoryPage({super.key, required this.patient});
  @override State<PatientHistoryPage> createState() => _PatientHistoryPageState();
}

class _PatientHistoryPageState extends State<PatientHistoryPage> {
  late Stream<QuerySnapshot> _historyStream;
  String _selectedSite = '全部';

  @override void initState() {
    super.initState();
    _historyStream = FirebaseFirestore.instance.collection('observations')
        .where('subject.reference', isEqualTo: 'Patient/${widget.patient.id}')
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.patient.name} - 歷程時間軸', style: const TextStyle(fontSize: 18))),
      body: SafeArea(
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 800),
            width: double.infinity, height: double.infinity,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  color: const Color(0xFF1E1E1E),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _infoItem(Icons.hotel, '床號', widget.patient.bedNumber),
                      _infoItem(Icons.badge, '病歷號', widget.patient.id),
                      _infoItem(Icons.analytics, 'Braden', '${widget.patient.bradenScore.toInt()}分')
                    ]
                  )
                ),
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: _historyStream,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
                      if (!snapshot.hasData || snapshot.data!.docs.isEmpty) return const Center(child: Text('目前無歷史紀錄，請新增', style: TextStyle(color: Colors.grey, fontSize: 16)));
                     
                      var docs = snapshot.data!.docs;
                      
                      Set<String> sites = {'全部'};
                      for (var d in docs) {
                        String s = (d.data() as Map)['bodySite']?['text'] ?? '';
                        if (s.isNotEmpty) sites.add(s);
                      }
           
                      var filteredDocs = docs;
                      if (_selectedSite != '全部') {
                        filteredDocs = docs.where((d) => ((d.data() as Map)['bodySite']?['text'] ?? '') == _selectedSite).toList();
                      }
                      
                      // 🌟 核心：將資料依照「日期」進行分組 (Time-Series)
                      Map<String, List<DocumentSnapshot>> groupedByDate = {};
                      for (var d in filteredDocs) {
                        final data = d.data() as Map<String, dynamic>;
                        String dateStr = '未知日期';
                        if (data['effectiveDateTime'] != null) {
                          DateTime dt = DateTime.parse(data['effectiveDateTime']).toLocal();
                          dateStr = '${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')}';
                        } else if (data['timestamp'] is Timestamp) {
                          DateTime dt = (data['timestamp'] as Timestamp).toDate().toLocal();
                          dateStr = '${dt.year}-${dt.month.toString().padLeft(2,'0')}-${dt.day.toString().padLeft(2,'0')}';
                        }
                        if (!groupedByDate.containsKey(dateStr)) groupedByDate[dateStr] = [];
                        groupedByDate[dateStr]!.add(d);
                      }
                      
                      // 日期由新到舊排序
                      var sortedDates = groupedByDate.keys.toList()..sort((a, b) => b.compareTo(a));
           
                      return Column(
                        children: [
                          Container(
                            width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), color: const Color(0xFF121212),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              physics: const AlwaysScrollableScrollPhysics(),
                              child: Row(
                                children: sites.map((site) {
                                  bool isSelected = _selectedSite == site;
                                  return Padding(
                                    padding: const EdgeInsets.only(right: 8.0),
                                    child: ChoiceChip(
                                      label: Text(site, style: TextStyle(color: isSelected ? Colors.white : Colors.grey.shade400, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal, fontSize: 13)),
                                      selected: isSelected, selectedColor: Colors.blueAccent, backgroundColor: const Color(0xFF2C2C2C), showCheckmark: false, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                      onSelected: (bool selected) { setState(() { _selectedSite = site; }); },
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                          Expanded(
                            child: filteredDocs.isEmpty
                                ? const Center(child: Text('此部位無歷史紀錄', style: TextStyle(color: Colors.white70, fontSize: 15)))
                                : ListView.builder(
                                    physics: const AlwaysScrollableScrollPhysics(),
                                    padding: const EdgeInsets.only(left: 10, right: 10, top: 4, bottom: 100),
                                    itemCount: sortedDates.length,
                                    itemBuilder: (context, index) {
                                      String dateKey = sortedDates[index];
                                      var dayDocs = groupedByDate[dateKey]!;
                                      // 同一天內，依據時間由新到舊排序
                                      dayDocs.sort((a, b) {
                                        String timeA = (a.data() as Map)['effectiveDateTime'] ?? '';
                                        String timeB = (b.data() as Map)['effectiveDateTime'] ?? '';
                                        return timeB.compareTo(timeA);
                                      });
                                      
                                      return Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          // 🌟 時間軸日期標頭
                                          Padding(
                                            padding: const EdgeInsets.only(top: 20, bottom: 12, left: 4),
                                            child: Row(
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                                  decoration: BoxDecoration(
                                                    color: Colors.blueAccent.withValues(alpha: 0.15),
                                                    borderRadius: BorderRadius.circular(20),
                                                    border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.5))
                                                  ),
                                                  child: Row(
                                                    children: [
                                                      const Icon(Icons.calendar_month, size: 16, color: Colors.blueAccent),
                                                      const SizedBox(width: 6),
                                                      Text(dateKey, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.blueAccent)),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(child: Container(height: 1, color: Colors.blueAccent.withValues(alpha: 0.2)))
                                              ],
                                            ),
                                          ),
                                          ...dayDocs.map((doc) => DualModalOverlayCard(
                                            docId: doc.id, data: doc.data() as Map<String, dynamic>,
                                            onDelete: () {
                                              showDialog(
                                                context: context,
                                                builder: (ctx) => AlertDialog(
                                                  title: const Text('⚠️ 刪除紀錄', style: TextStyle(fontSize: 18)),
                                                  content: const Text('確定刪除紀錄？', style: TextStyle(fontSize: 15)),
                                                  actions: [
                                                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                                                    ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent), onPressed: () async { 
                                                      Navigator.pop(ctx); 
                                                      await FirebaseFirestore.instance.collection('observations').doc(doc.id).delete(); 
                                                    }, child: const Text('刪除', style: TextStyle(color: Colors.white)))
                                                  ]
                                                )
                                              );
                                            }
                                          ))
                                        ],
                                      );
                                    }
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => BodyPartSelectionPage(patient: widget.patient))),
        icon: const Icon(Icons.camera_alt, size: 20),
        label: const Text('新增紀錄', style: TextStyle(fontSize: 15)),
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white
      ),
    );
  }
  Widget _infoItem(IconData icon, String label, String value) => Column(children: [Icon(icon, color: Colors.grey, size: 20), const SizedBox(height: 4), Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)), Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14))]);
}

// =======================================================
// === 拍攝流程：全螢幕引導精靈 ===
// =======================================================
class WoundCaptureWizardPage extends StatefulWidget {
  final String partName;
  const WoundCaptureWizardPage({super.key, required this.partName});
  @override State<WoundCaptureWizardPage> createState() => _WoundCaptureWizardPageState();
}
class _WoundCaptureWizardPageState extends State<WoundCaptureWizardPage> {
  int _currentStep = 0;
  final ImagePicker _picker = ImagePicker();
  final ThermalCameraService _thermalService = MockThermalCamera();
  Uint8List? rgbBytes;
  Uint8List? thermalBytes;
 
  Offset _woundPoint = const Offset(0.5, 0.5);
  Offset _refPoint = const Offset(0.2, 0.8);  
  double _woundTemp = 38.2;
  double _referenceTemp = 35.8;
  DateTime _selectedCaptureTime = DateTime.now(); // 🌟 預設為當下時間
 
  final WoundFeatureData featureData = WoundFeatureData();
  
  // 🌟 新增時間挑選器
  Future<void> _pickDateTime() async {
    final DateTime? date = await showDatePicker(context: context, initialDate: _selectedCaptureTime, firstDate: DateTime(2020), lastDate: DateTime.now());
    if (date != null && mounted) {
      final TimeOfDay? time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_selectedCaptureTime));
      if (time != null) {
        setState(() {
          _selectedCaptureTime = DateTime(date.year, date.month, date.day, time.hour, time.minute);
        });
      }
    }
  }

  Future<void> _captureRGB() async {
    try {
      final photo = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 60, maxWidth: 600, maxHeight: 600);
      if (photo == null) return;
      final bytes = await photo.readAsBytes();
      setState(() { rgbBytes = bytes; });
    } catch (e) { debugPrint(e.toString()); }
  }
  
  Future<void> _captureThermal() async {
    final thermalData = await _thermalService.captureThermalData();
    if (thermalData != null) {
      setState(() {
        thermalBytes = thermalData['imageBytes'];
        _woundTemp = thermalData['woundTemp'];
        _referenceTemp = thermalData['referenceTemp'];
      });
    }
  }
  
  Widget _buildDraggableMarker({
    required Offset position,
    required BoxConstraints constraints,
    required Color color,
    required IconData icon,
    required Function(Offset) onUpdate,
  }) {
    const double touchAreaSize = 56.0;
    return Positioned(
      left: position.dx * constraints.maxWidth - touchAreaSize / 2,
      top: position.dy * constraints.maxHeight - touchAreaSize / 2,
      child: GestureDetector(
        onPanUpdate: (details) {
          double newDx = position.dx + (details.delta.dx / constraints.maxWidth);
          double newDy = position.dy + (details.delta.dy / constraints.maxHeight);
          onUpdate(Offset(newDx.clamp(0.05, 0.95), newDy.clamp(0.05, 0.95)));
        },
        child: Container(
          width: touchAreaSize, height: touchAreaSize, color: Colors.transparent,
          child: Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 30, height: 30,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.3),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 4)]
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
      appBar: AppBar(title: Text('標記部位：${widget.partName}', style: const TextStyle(fontSize: 18))),
      body: SafeArea(
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 800),
            width: double.infinity, height: double.infinity,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 12), color: const Color(0xFF1E1E1E),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildStepIcon(0, Icons.camera_alt, '1. 光學'),
                      const Icon(Icons.arrow_forward_ios, color: Colors.grey, size: 12),
                      _buildStepIcon(1, Icons.thermostat, '2. 熱影像與ΔT'),
                      const Icon(Icons.arrow_forward_ios, color: Colors.grey, size: 12),
                      _buildStepIcon(2, Icons.assignment, '3. 評估')
                    ]
                  )
                ),
                Expanded(child: SingleChildScrollView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(20.0), child: _buildCurrentStepContent())),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  Widget _buildStepIcon(int stepIndex, IconData icon, String label) {
    bool isActive = _currentStep == stepIndex; bool isPast = _currentStep > stepIndex;
    Color color = isActive ? Colors.blueAccent : (isPast ? Colors.green : Colors.grey);
    return Column(children: [CircleAvatar(backgroundColor: color.withValues(alpha: 0.2), radius: 20, child: Icon(icon, color: color, size: 20)), const SizedBox(height: 4), Text(label, style: TextStyle(color: color, fontWeight: isActive ? FontWeight.bold : FontWeight.normal, fontSize: 12))]);
  }
  
  Widget _buildCurrentStepContent() {
    if (_currentStep == 0) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 🌟 加入時間修改區塊
          Container(
            margin: const EdgeInsets.only(bottom: 20), padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white12)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('評估記錄時間 (支援事後補登)', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    const SizedBox(height: 4),
                    Text('${_selectedCaptureTime.year}-${_selectedCaptureTime.month.toString().padLeft(2,'0')}-${_selectedCaptureTime.day.toString().padLeft(2,'0')} ${_selectedCaptureTime.hour.toString().padLeft(2,'0')}:${_selectedCaptureTime.minute.toString().padLeft(2,'0')}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.blueAccent)),
                  ],
                ),
                TextButton.icon(onPressed: _pickDateTime, icon: const Icon(Icons.edit, size: 16), label: const Text('修改'))
              ],
            ),
          ),

          const Text('請拍攝傷口 RGB 光學影像', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('提示：移除敷料，保持鏡頭垂直傷口', style: TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 20),
          if (rgbBytes != null)
            ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(rgbBytes!, width: double.infinity, fit: BoxFit.contain, filterQuality: FilterQuality.low)),
          if (rgbBytes == null)
            GestureDetector(
              onTap: _captureRGB,
              child: AspectRatio(
                aspectRatio: 4/3,
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.blueAccent, width: 2)),
                  child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.camera_alt, size: 50, color: Colors.blueAccent), SizedBox(height: 8), Text('點擊選取光學影像', style: TextStyle(fontSize: 16, color: Colors.blueAccent))])
                )
              )
            ),
          const SizedBox(height: 28),
          if (rgbBytes != null)
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: _captureRGB, child: const Text('重拍'))),
              const SizedBox(width: 12),
              Expanded(child: ElevatedButton(onPressed: () => setState(() => _currentStep = 1), child: const Text('下一步')))
            ])
        ]
      );
    } else if (_currentStep == 1) {
      double deltaT = _woundTemp - _referenceTemp;
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('熱影像採集與 ΔT 溫差測量', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text('👉 直接按住並拖曳畫面上的 🔴 與 🔵 標記', style: TextStyle(color: Colors.lightBlueAccent, fontSize: 13, fontWeight: FontWeight.bold)),
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
                        Image.memory(thermalBytes!, width: constraints.maxWidth, height: constraints.maxHeight, fit: BoxFit.fill, filterQuality: FilterQuality.low),
                       
                        _buildDraggableMarker(
                          position: _refPoint,
                          constraints: constraints,
                          color: Colors.blueAccent,
                          icon: Icons.adjust,
                          onUpdate: (newOffset) {
                            setState(() {
                              _refPoint = newOffset;
                              _referenceTemp = double.parse((35.0 + (_refPoint.dx * 1.5)).toStringAsFixed(1));
                            });
                          }
                        ),
                        _buildDraggableMarker(
                          position: _woundPoint,
                          constraints: constraints,
                          color: Colors.redAccent,
                          icon: Icons.gps_fixed,
                          onUpdate: (newOffset) {
                            setState(() {
                              _woundPoint = newOffset;
                              _woundTemp = double.parse((37.0 + (_woundPoint.dy * 2.5)).toStringAsFixed(1));
                            });
                          }
                        ),
                      ],
                    );
                  }
                ),
              )
            ),
            const SizedBox(height: 12),
           
            Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(8), border: Border.all(color: deltaT >= 2.0 ? Colors.redAccent : Colors.greenAccent)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Text('🔴 傷口: $_woundTemp°C', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  Text('🔵 對照: $_referenceTemp°C', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  Text('ΔT: ${deltaT >= 0 ? "+" : ""}${deltaT.toStringAsFixed(1)}°C', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: deltaT >= 2.0 ? Colors.redAccent : Colors.greenAccent)),
                ],
              ),
            ),
          ],
         
          if (thermalBytes == null)
            GestureDetector(
              onTap: _captureThermal,
              child: AspectRatio(
                aspectRatio: 4/3,
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.deepOrangeAccent, width: 2)),
                  child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.thermostat, size: 50, color: Colors.deepOrangeAccent), SizedBox(height: 8), Text('點擊選取熱影像', style: TextStyle(fontSize: 16, color: Colors.deepOrangeAccent))])
                )
              )
            ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(child: OutlinedButton(onPressed: () => setState(() => _currentStep = 0), child: const Text('上一步'))),
              if (thermalBytes != null) ...[
                const SizedBox(width: 12),
                Expanded(child: ElevatedButton(onPressed: () => setState(() => _currentStep = 2), child: const Text('下一步')))
              ]
            ]
          )
        ]
      );
    } else {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('📝 臨床特徵評估', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          const Text('滲液量 (Exudate)', style: TextStyle(fontSize: 15, color: Colors.amberAccent)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14), decoration: BoxDecoration(color: const Color(0xFF2C2C2C), borderRadius: BorderRadius.circular(8)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: featureData.exudateAmount, isExpanded: true, style: const TextStyle(fontSize: 16, color: Colors.white),
                items: ['無', '少量', '中量', '大量'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                onChanged: (val) => setState(() => featureData.exudateAmount = val!)
              )
            )
          ),
          const SizedBox(height: 20),
          const Text('主要組織狀態 (Tissue Type)', style: TextStyle(fontSize: 15, color: Colors.lightGreenAccent)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14), decoration: BoxDecoration(color: const Color(0xFF2C2C2C), borderRadius: BorderRadius.circular(8)),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: featureData.tissueType, isExpanded: true, style: const TextStyle(fontSize: 16, color: Colors.white),
                items: ['紅色肉芽組織', '黃色腐肉', '黑色焦痂', '上皮化組織'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                onChanged: (val) => setState(() => featureData.tissueType = val!)
              )
            )
          ),
          const SizedBox(height: 32),
          Row(
            children: [
              Expanded(child: OutlinedButton(onPressed: () => setState(() => _currentStep = 1), child: const Text('上一步'))),
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
                      captureTime: _selectedCaptureTime, // 🌟 傳入選定的時間
                    );
                    Navigator.pop(context, record);
                  },
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('完成並暫存'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green)
                )
              )
            ]
          )
        ]
      );
    }
  }
}

// =======================================================
// === 第三頁：部位選擇與上傳 ===
// =======================================================
class BodyPartSelectionPage extends StatefulWidget {
  final Patient patient;
  const BodyPartSelectionPage({super.key, required this.patient});
  @override State<BodyPartSelectionPage> createState() => _BodyPartSelectionPageState();
}
class _BodyPartSelectionPageState extends State<BodyPartSelectionPage> {
  bool isBackView = true;
  final Map<String, WoundPhotoRecord> _capturedWounds = {};
  late Stream<QuerySnapshot> _woundsStream;
  
  @override 
  void initState() {
    super.initState();
    _woundsStream = FirebaseFirestore.instance.collection('observations').where('subject.reference', isEqualTo: 'Patient/${widget.patient.id}').snapshots();
  }
  
  void _exportFHIRJson() {
    if (_capturedWounds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⚠️️ 尚未拍攝任何部位影像', style: TextStyle(fontSize: 15)), backgroundColor: Colors.orange));
      return;
    }
    
    List<Map<String, dynamic>> fhirBundle = [];
    for (var entry in _capturedWounds.entries) {
      String partName = entry.key;
      WoundPhotoRecord record = entry.value;
      
      final fhirObservation = FhirWoundObservation(
        subject: widget.patient,
        bodySite: partName,
        bradenScore: widget.patient.bradenScore,
        features: record.features,
        rgbBase64: base64Encode(record.rgbBytes),
        thermalBase64: base64Encode(record.thermalBytes),
        woundTemp: record.woundTemp,
        referenceTemp: record.referenceTemp,
        captureTime: record.captureTime, // 🌟 FHIR 綁定時間
      );
      fhirBundle.add(fhirObservation.toFhirJson());
    }
    JsonEncoder encoder = const JsonEncoder.withIndent('  ');
    String jsonString = encoder.convert(fhirBundle);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(children: [Icon(Icons.data_object, color: Colors.blueAccent), SizedBox(width: 8), Text('匯出 FHIR JSON')]),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8)),
            child: SingleChildScrollView(
              child: SelectableText(jsonString, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.greenAccent)),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('關閉', style: TextStyle(color: Colors.grey))),
          ElevatedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: jsonString)); 
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ JSON 已複製到剪貼簿！可直接貼上存檔', style: TextStyle(fontSize: 14)), backgroundColor: Colors.green));
                Navigator.pop(context);
              }
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('複製全部'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
          )
        ]
      )
    );
  }
  
  Future<void> _uploadAllToHospitalSystem() async {
    if (_capturedWounds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⚠️ 尚未拍攝任何部位影像', style: TextStyle(fontSize: 15)), backgroundColor: Colors.orange));
      return;
    }
    showDialog(context: context, barrierDismissible: false, builder: (context) => const Center(child: CircularProgressIndicator()));
    try {
      final firestore = FirebaseFirestore.instance;
      for (var entry in _capturedWounds.entries) {
        String partName = entry.key;
        WoundPhotoRecord record = entry.value;
       
        final fhirObservation = FhirWoundObservation(
          subject: widget.patient,
          bodySite: partName,
          bradenScore: widget.patient.bradenScore,
          features: record.features,
          rgbBase64: base64Encode(record.rgbBytes),
          thermalBase64: base64Encode(record.thermalBytes),
          woundTemp: record.woundTemp,
          referenceTemp: record.referenceTemp,
          captureTime: record.captureTime, // 🌟 FHIR 綁定時間
        );
        Map<String, dynamic> finalJson = fhirObservation.toFhirJson();
        finalJson['timestamp'] = FieldValue.serverTimestamp(); // 🌟 雙軌時間戳：供系統稽核
        await firestore.collection('observations').add(finalJson).timeout(const Duration(seconds: 10));
      }
      if (!mounted) return;
      Navigator.pop(context); Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('🎉 FHIR 病歷上傳成功！', style: TextStyle(fontSize: 15)), backgroundColor: Colors.green));
    } catch (e) {
      if (!mounted) return; Navigator.pop(context); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('上傳失敗: $e'), backgroundColor: Colors.redAccent));
    }
  }
  
  Widget _viewButton(String label, IconData icon, bool viewState) => ElevatedButton.icon(
    onPressed: () => setState(() => isBackView = viewState), 
    icon: Icon(icon, size: 18), 
    label: Text(label, style: const TextStyle(fontSize: 14)), 
    style: ElevatedButton.styleFrom(
      backgroundColor: isBackView == viewState ? Colors.blueAccent : const Color(0xFF2C2C2C), 
      foregroundColor: Colors.white, 
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8)
    )
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
  
  Widget _point(BuildContext context, double xPercent, double yPercent, String name, Set<String> existing) {
    bool isTaken = _capturedWounds.containsKey(name) || existing.contains(name);
   
    return Align(
      alignment: Alignment(
        (xPercent * 2) - 1,
        (yPercent * 2) - 1
      ),
      child: GestureDetector(
        onTap: () async {
          if (isTaken) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⚠️ 已有紀錄，請至歷史紀錄刪除重拍。', style: TextStyle(fontSize: 14))));
          } else {
            final WoundPhotoRecord? result = await Navigator.push(context, MaterialPageRoute(builder: (context) => WoundCaptureWizardPage(partName: name)));
            if (result != null) {
              setState(() { _capturedWounds[name] = result; });
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ 評估已暫存，請繼續標記或點擊上傳', style: TextStyle(fontSize: 14)), backgroundColor: Colors.green));
            }
          }
        },
        child: Container(
          width: 36, 
          height: 36,
          decoration: BoxDecoration(
            color: isTaken ? Colors.greenAccent.withValues(alpha: 0.9) : Colors.redAccent.withValues(alpha: 0.85), 
            shape: BoxShape.circle, 
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4)]
          ), 
          child: Icon(isTaken ? Icons.check : Icons.add, size: 20, color: Colors.white)
        ),
      ),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    bool isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.patient.name} - 部位選擇', style: const TextStyle(fontSize: 18))),
      body: SafeArea(
        child: StreamBuilder<QuerySnapshot>(
          stream: _woundsStream,
          builder: (context, snapshot) {
            Set<String> existingWounds = {};
            if (snapshot.hasData) { 
              for (var doc in snapshot.data!.docs) { 
                var data = doc.data() as Map<String, dynamic>; 
                if (data['bodySite'] != null && data['bodySite']['text'] != null) {
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
                      _viewButton('正面觀', Icons.person, false)
                    ]
                  ),
                  const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Text('點選圖上位置進行拍攝：', style: TextStyle(color: Colors.grey, fontSize: 14))),
                 
                  LayoutBuilder(
                    builder: (context, constraints) {
                      double maxWidth = constraints.maxWidth;
                      double containerWidth;
                      if (maxWidth > 600) {
                        double screenHeight = MediaQuery.of(context).size.height;
                        double targetHeight = screenHeight * 0.65; 
                        containerWidth = targetHeight * (350 / 600); 
                      } else {
                        containerWidth = isLandscape ? 180 : (maxWidth > 380 ? 380 : maxWidth * 0.92);
                      }
                      double containerHeight = containerWidth * (600 / 350);
                     
                      return Center(
                        child: Container(
                          width: containerWidth, height: containerHeight, decoration: BoxDecoration(color: const Color(0xFF1E1E1E), border: Border.all(color: Colors.grey.shade800), borderRadius: BorderRadius.circular(16)),
                          child: Stack(
                            alignment: Alignment.center,
                            clipBehavior: Clip.none,
                            children: [
                              ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.asset(isBackView ? 'assets/images/body_back.png.jpg' : 'assets/images/body_front.png.jpg', width: containerWidth, height: containerHeight, fit: BoxFit.fill, errorBuilder: (c,e,s) => const Center(child: Text("找不到圖片")))),
                              
                              if (isBackView) ..._buildBackDots(context, existingWounds),
                              if (!isBackView) ..._buildFrontDots(context, existingWounds),
                            ],
                          ),
                        ),
                      );
                    }
                  ),
                  const SizedBox(height: 150),
                ],
              ),
            );
          }
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
            foregroundColor: Colors.white
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'upload_db',
            onPressed: _uploadAllToHospitalSystem,
            icon: const Icon(Icons.cloud_upload, size: 20),
            label: const Text('上傳 FHIR 病歷', style: TextStyle(fontSize: 15)),
            backgroundColor: Colors.green,
            foregroundColor: Colors.white
          ),
        ],
      ),
    );
  }
}