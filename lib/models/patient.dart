class Patient {
  final String bedNumber;
  final String name;
  final String id;
  final String gender;
  final int age;
  final double bradenScore;

  const Patient({
    required this.bedNumber,
    required this.name,
    required this.id,
    required this.gender,
    required this.age,
    required this.bradenScore,
  });

  Map<String, dynamic> toJson() => {
        'bedNumber': bedNumber,
        'name': name,
        'id': id,
        'gender': gender,
        'age': age,
        'bradenScore': bradenScore,
      };

  factory Patient.fromJson(Map<String, dynamic> json) => Patient(
        bedNumber: json['bedNumber'] ?? '',
        name: json['name'] ?? '',
        id: json['id'] ?? '',
        gender: json['gender'] ?? '男',
        age: json['age'] is num
            ? (json['age'] as num).toInt()
            : int.tryParse(json['age']?.toString() ?? '0') ?? 0,
        bradenScore: json['bradenScore'] is num
            ? (json['bradenScore'] as num).toDouble()
            : double.tryParse(json['bradenScore']?.toString() ?? '23') ?? 23.0,
      );
}