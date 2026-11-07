import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/patient.dart';

class PatientRecord {
  final String documentId;
  final Patient patient;

  const PatientRecord({required this.documentId, required this.patient});
}

abstract class PatientRepository {
  Stream<List<PatientRecord>> watchPatients();
  Future<void> addPatient(Patient patient);
  Future<void> deletePatient(String documentId);
}

class FirestorePatientRepository implements PatientRepository {
  const FirestorePatientRepository();

  @override
  Stream<List<PatientRecord>> watchPatients() {
    return FirebaseFirestore.instance.collection('patients').snapshots().map(
          (snapshot) => snapshot.docs
              .map(
                (document) => PatientRecord(
                  documentId: document.id,
                  patient: Patient.fromJson(document.data()),
                ),
              )
              .toList(),
        );
  }

  @override
  Future<void> addPatient(Patient patient) async {
    await FirebaseFirestore.instance.collection('patients').add(patient.toJson());
  }

  @override
  Future<void> deletePatient(String documentId) async {
    await FirebaseFirestore.instance.collection('patients').doc(documentId).delete();
  }
}