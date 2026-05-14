import 'package:flutter/material.dart';
import 'edit_profile_page.dart';
import 'change_password_page.dart';

class SettingsPage extends StatelessWidget {
  final Function(bool) toggleTheme;
  final bool isDarkMode;

  const SettingsPage({
    super.key,
    required this.toggleTheme,
    required this.isDarkMode,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Settings"),
      ),
      body: ListView(
        children: [

          ListTile(
            leading: const Icon(Icons.dark_mode),
            title: const Text("Dark Mode"),
            trailing: Switch(
              value: isDarkMode,
              onChanged: toggleTheme,
            ),
          ),

          ListTile(
            leading: const Icon(Icons.person),
            title: const Text("Edit Profile"),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const EditProfilePage(
                    name: "",
                    email: "",
                  ),
                ),
              );
            },
          ),

          ListTile(
            leading: const Icon(Icons.lock),
            title: const Text("Change Password"),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const ChangePasswordPage(),
                ),
              );
            },
          ),

          ListTile(
            leading: const Icon(Icons.notifications),
            title: const Text("Notifications"),
          ),

          ListTile(
            leading: const Icon(Icons.location_on),
            title: const Text("Location Settings"),
          ),

          ListTile(
            leading: const Icon(Icons.contacts),
            title: const Text("Emergency Contacts"),
          ),

          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text("Logout"),
          ),

        ],
      ),
    );
  }
}