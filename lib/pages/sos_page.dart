import 'package:flutter/material.dart';

class SosPage extends StatefulWidget {
  const SosPage({super.key});

  @override
  State<SosPage> createState() => _SosPageState();
}

class _SosPageState extends State<SosPage> {
  bool isSafe = false;

  void toggleStatus() {
    setState(() {
      isSafe = !isSafe;
    });

    if (isSafe) {
      print("User is SAFE");
    } else {
      print("SOS! User is in DANGER");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Emergency Status",
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.black,
      ),
      body: Center(
        child: ElevatedButton(
          onPressed: toggleStatus,
          style: ElevatedButton.styleFrom(
            backgroundColor: isSafe ? Colors.green : Colors.red,
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
          ),
          child: Text(
            isSafe ? "I AM SAFE" : "SOS",
            style: const TextStyle(fontSize: 24, color: Colors.white),
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.sos, color: Colors.black),
            label: "SOS",
          ),
          NavigationDestination(icon: Icon(Icons.map_rounded), label: "Map"),
          NavigationDestination(
            icon: Icon(Icons.contacts_rounded),
            label: "Contacts",
          ),
          NavigationDestination(icon: Icon(Icons.settings), label: "Settings"),
        ],
      ),
    );
  }
}
