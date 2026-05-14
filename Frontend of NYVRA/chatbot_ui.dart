import 'dart:ui';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class ChatBotUI extends StatefulWidget {
  const ChatBotUI({super.key});

  @override
  State<ChatBotUI> createState() => _ChatBotUIState();
}

class _ChatBotUIState extends State<ChatBotUI> {
  final TextEditingController controller = TextEditingController();

  List<Map<String, String>> messages = [
    {
      "role": "bot",
      "text": "Hi I'm your Nyvra AI Safety Assistant.\nAsk me anything!"
    }
  ];

  final List<String> faqs = [
    "What to do in danger?",
    "Is this area safe?",
    "Nearest police station",
    "Safe route at night",
  ];
  void openPoliceStation() async {
    final url = Uri.parse(
        "https://www.google.com/maps/search/police+station+near+me"
    );

    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  //////////////////////////////////////////////////////
  // SEND MESSAGE
  //////////////////////////////////////////////////////
  void sendMessage(String text) {
    if (text.trim().isEmpty) return;

    setState(() {
      messages.add({"role": "user", "text": text});
    });

    controller.clear();

    String lowerText = text.toLowerCase();

    // 🚔 POLICE → open maps
    if (lowerText.contains("police")) {
      openPoliceStation();

      setState(() {
        messages.add({
          "role": "bot",
          "text": "🚔 Opening nearest police stations..."
        });
      });
      return;
    }

    // 🚨 DANGER → instant response (no API)
    if (lowerText.contains("danger")) {
      setState(() {
        messages.add({
          "role": "bot",
          "text": " Call 112 immediately and move to a safe place!"
        });
      });
      return;
    }

    // 🤖 AI CALL
    Future.delayed(const Duration(milliseconds: 300), () async {
      String reply = await getBotResponse(text);

      setState(() {
        messages.add({"role": "bot", "text": reply});
      });
    });
  }

  //////////////////////////////////////////////////////
  // 🤖 AI RESPONSE FUNCTION (FIXED)
  //////////////////////////////////////////////////////
  Future<String> getBotResponse(String msg) async {
    try {
      final response = await http.post(
        Uri.parse("https://supriyachola-nyvra-api.hf.space/ai"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"message": msg}),
      );

      // debugPrint("STATUS: ${response.statusCode}");
      // debugPrint("BODY: ${response.body}");

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data["reply"] ?? "No response";
      }

      return "⚠️ Server error ${response.statusCode}";
    } catch (e) {
      debugPrint("ERROR: $e");
      return "⚠️ Cannot connect to backend";
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  //////////////////////////////////////////////////////
  // UI
  //////////////////////////////////////////////////////
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(25)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            height: MediaQuery.of(context).size.height * 0.8,
            color: Colors.black.withValues(alpha: 0.6),
            child: Column(
              children: [
                const SizedBox(height: 10),

                Container(
                  height: 5,
                  width: 50,
                  decoration: BoxDecoration(
                    color: Colors.white30,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),

                const SizedBox(height: 15),

                const Text(
                  "Nyvra Assistant",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const Divider(color: Colors.white24),

                //////////////////////////////////////////////////////
                // FAQ BUTTONS
                //////////////////////////////////////////////////////
                SizedBox(
                  height: 45,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: faqs.length,
                    itemBuilder: (context, index) {
                      return GestureDetector(
                        onTap: () => sendMessage(faqs[index]),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 15, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: Text(
                            faqs[index],
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      );
                    },
                  ),
                ),

                const SizedBox(height: 10),

                //////////////////////////////////////////////////////
                // MESSAGES
                //////////////////////////////////////////////////////
                Expanded(
                  child: ListView.builder(
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final msg = messages[index];
                      bool isUser = msg["role"] == "user";

                      return Container(
                        alignment: isUser
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        padding: const EdgeInsets.all(10),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isUser
                                ? Colors.blueAccent.withValues(alpha: 0.7)
                                : Colors.white.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Text(
                            msg["text"]!,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      );
                    },
                  ),
                ),

                //////////////////////////////////////////////////////
                // INPUT
                //////////////////////////////////////////////////////
                Container(
                  padding: const EdgeInsets.all(10),
                  color: Colors.black.withValues(alpha: 0.6),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: controller,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            hintText: "Ask about safety...",
                            hintStyle: TextStyle(color: Colors.white54),
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.send,
                            color: Colors.blueAccent),
                        onPressed: () => sendMessage(controller.text),
                      )
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}