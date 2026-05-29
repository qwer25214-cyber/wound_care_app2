import 'package:flutter/material.dart';

void main() {
  runApp(const WoundCareApp());
}

class WoundCareApp extends StatelessWidget {
  const WoundCareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '傷口預警系統',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const PatientListPage(),
    );
  }
}

// === 資料模型 ===
class Patient {
  final String bedNumber;
  final String name;
  final String id;
  final double bradenScore;
  Patient({required this.bedNumber, required this.name, required this.id, required this.bradenScore});
}

// === 第一頁：病患清單與新增功能 ===
class PatientListPage extends StatefulWidget {
  const PatientListPage({super.key});
  @override
  State<PatientListPage> createState() => _PatientListPageState();
}

class _PatientListPageState extends State<PatientListPage> {
  final List<Patient> patients = [
    Patient(bedNumber: '301-A', name: '張曉明', id: 'A123456***', bradenScore: 12),
    Patient(bedNumber: '305-C', name: '王大同', id: 'C112233***', bradenScore: 9),
  ];

  // 彈出新增病患視窗
  void _showAddPatientDialog() {
    final bedController = TextEditingController();
    final nameController = TextEditingController();
    final scoreController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新增病患資料'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: bedController, decoration: const InputDecoration(labelText: '床號 (例: 305-C)')),
            TextField(controller: nameController, decoration: const InputDecoration(labelText: '姓名')),
            TextField(controller: scoreController, decoration: const InputDecoration(labelText: 'Braden 評分 (6-23)'), keyboardType: TextInputType.number),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          ElevatedButton(
            onPressed: () {
              if (nameController.text.isNotEmpty) {
                setState(() {
                  patients.add(Patient(
                    bedNumber: bedController.text.isEmpty ? '未分配' : bedController.text,
                    name: nameController.text,
                    id: '新建立',
                    bradenScore: double.tryParse(scoreController.text) ?? 23,
                  ));
                });
                Navigator.pop(context); // 關閉視窗
              }
            },
            child: const Text('新增'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('病患傷口監測清單', style: TextStyle(fontWeight: FontWeight.bold)), 
        backgroundColor: Colors.blue[100]
      ),
      body: ListView.builder(
        itemCount: patients.length,
        itemBuilder: (context, index) {
          final patient = patients[index];
          Color scoreColor = patient.bradenScore <= 12 ? Colors.red : (patient.bradenScore <= 14 ? Colors.orange : Colors.green);
          String riskLevel = patient.bradenScore <= 12 ? '高風險' : (patient.bradenScore <= 14 ? '中風險' : '低風險');

          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: ListTile(
              leading: CircleAvatar(backgroundColor: Colors.blue[700], foregroundColor: Colors.white, child: Text(patient.bedNumber.split('-')[0])),
              title: Text('${patient.bedNumber} 房 - ${patient.name}', style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('病歷號: ${patient.id}'),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(riskLevel, style: TextStyle(color: scoreColor, fontWeight: FontWeight.bold)),
                  Text('Braden: ${patient.bradenScore}分', style: const TextStyle(fontSize: 12)),
                ],
              ),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (context) => BodyPartSelectionPage(patient: patient))),
            ),
          );
        },
      ),
      // 新增病患按鈕
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddPatientDialog,
        icon: const Icon(Icons.person_add),
        label: const Text('新增病患'),
        backgroundColor: Colors.blue[700],
        foregroundColor: Colors.white,
      ),
    );
  }
}

// === 第二頁：部位選擇 ===
class BodyPartSelectionPage extends StatefulWidget {
  final Patient patient;
  const BodyPartSelectionPage({super.key, required this.patient});

  @override
  State<BodyPartSelectionPage> createState() => _BodyPartSelectionPageState();
}

class _BodyPartSelectionPageState extends State<BodyPartSelectionPage> {
  bool isBackView = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('${widget.patient.name} - 選擇部位'), backgroundColor: Colors.blue[100]),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: () => setState(() => isBackView = true),
                    icon: const Icon(Icons.person_search),
                    label: const Text('背面觀'),
                    style: ElevatedButton.styleFrom(backgroundColor: isBackView ? Colors.blue[200] : null),
                  ),
                  const SizedBox(width: 20),
                  ElevatedButton.icon(
                    onPressed: () => setState(() => isBackView = false),
                    icon: const Icon(Icons.person),
                    label: const Text('正面觀'),
                    style: ElevatedButton.styleFrom(backgroundColor: !isBackView ? Colors.blue[200] : null),
                  ),
                ],
              ),
            ),

            const Text('請點選圖上相應位置進行拍攝：', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),

            Center(
              child: Container(
                width: 350,
                height: 600,
                decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(12)),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset(
                        isBackView ? 'assets/images/body_back.png.jpg' : 'assets/images/body_front.png.jpg',
                        width: 350,
                        height: 600,
                        fit: BoxFit.contain,
                      ),
                    ),
                    
                    if (isBackView) ..._buildBackDots(context),
                    if (!isBackView) ..._buildFrontDots(context),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildBackDots(BuildContext context) {
    return [
      _point(context, 75, 165, '後腦勺 (Back of Head)'),
      _point(context, 160, 105, '左側肩胛骨 (L Shoulder Blade)'),
      _point(context, 160, 225, '右側肩胛骨 (R Shoulder Blade)'),
      _point(context, 230, 165, '脊椎 (Spine)'),
      _point(context, 290, 165, '薦骨/尾椎 (Sacrum)'),
      _point(context, 555, 125, '左側足跟 (L Heel)'),
      _point(context, 555, 205, '右側足跟 (R Heel)'),
    ];
  }

  List<Widget> _buildFrontDots(BuildContext context) {
    return [
      _point(context, 100, 125, '右側耳部 (R Ear)'),
      _point(context, 100, 205, '左側耳部 (L Ear)'),
      _point(context, 160, 95, '右側肩部 (R Shoulder)'),
      _point(context, 160, 235, '左側肩部 (L Shoulder)'),
      _point(context, 220, 165, '胸廓中央 (Chest)'),
      _point(context, 300, 110, '右側髖部 (R Hip)'),
      _point(context, 300, 220, '左側髖部 (L Hip)'),
      _point(context, 435, 125, '右側膝蓋 (R Knee)'),
      _point(context, 435, 205, '左側膝蓋 (L Knee)'),
      _point(context, 585, 125, '右側足趾 (R Toes)'),
      _point(context, 585, 205, '左側足趾 (L Toes)'),
    ];
  }

  Widget _point(BuildContext context, double top, double left, String name) {
    return Positioned(
      top: top,
      left: left,
      child: GestureDetector(
        onTap: () => _showGuide(context, name),
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: Colors.red.withOpacity(0.8),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
          ),
          child: const Icon(Icons.add, size: 16, color: Colors.white),
        ),
      ),
    );
  }

  void _showGuide(BuildContext context, String partName) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('選定拍攝部位：', style: TextStyle(fontSize: 14, color: Colors.grey)),
            Text(partName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.blue)),
            const Divider(height: 30),
            const Text('• 請確保鏡頭與皮膚保持平行', style: TextStyle(fontSize: 16)),
            const Text('• 距離皮膚約一個手掌寬度', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.camera_alt),
                label: const Text('開始拍攝'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white, padding: const EdgeInsets.all(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}