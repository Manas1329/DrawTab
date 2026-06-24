import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class InputPanelScreen extends StatefulWidget {
  final void Function(Map<String, dynamic>) sendCommand;

  const InputPanelScreen({super.key, required this.sendCommand});

  @override
  State<InputPanelScreen> createState() => _InputPanelScreenState();
}

class CustomShortcut {
  final String label;
  final List<String> keys;

  CustomShortcut({required this.label, required this.keys});

  Map<String, dynamic> toJson() => {
    'label': label,
    'keys': keys,
  };

  factory CustomShortcut.fromJson(Map<String, dynamic> json) {
    return CustomShortcut(
      label: json['label'],
      keys: List<String>.from(json['keys']),
    );
  }
}

class _InputPanelScreenState extends State<InputPanelScreen> {
  List<CustomShortcut> _shortcuts = [];
  bool _shiftActive = false;
  bool _ctrlActive = false;
  bool _altActive = false;
  bool _winActive = false;

  @override
  void initState() {
    super.initState();
    _loadShortcuts();
  }

  Future<void> _loadShortcuts() async {
    final prefs = await SharedPreferences.getInstance();
    final shortcutsJson = prefs.getStringList('custom_shortcuts') ?? [];
    setState(() {
      _shortcuts = shortcutsJson
          .map((e) => CustomShortcut.fromJson(jsonDecode(e)))
          .toList();
      
      if (_shortcuts.isEmpty) {
        _shortcuts = [
          CustomShortcut(label: 'Undo', keys: ['ctrl', 'z']),
          CustomShortcut(label: 'Save', keys: ['ctrl', 's']),
          CustomShortcut(label: 'Copy', keys: ['ctrl', 'c']),
          CustomShortcut(label: 'Paste', keys: ['ctrl', 'v']),
        ];
        _saveShortcuts();
      }
    });
  }

  Future<void> _saveShortcuts() async {
    final prefs = await SharedPreferences.getInstance();
    final shortcutsJson = _shortcuts.map((e) => jsonEncode(e.toJson())).toList();
    await prefs.setStringList('custom_shortcuts', shortcutsJson);
  }

  void _sendKeyCommand(List<String> keys) {
    try {
      widget.sendCommand({
        'cmd': 'key',
        'keys': keys,
      });
    } catch (e) {
      debugPrint("Failed to send key command: $e");
    }
  }

  void _handleKeyPress(String key) {
    List<String> keysToSend = [];
    if (_ctrlActive) keysToSend.add('ctrl');
    if (_shiftActive) keysToSend.add('shift');
    if (_altActive) keysToSend.add('alt');
    if (_winActive) keysToSend.add('cmd'); 

    keysToSend.add(key);
    _sendKeyCommand(keysToSend);
  }

  void _addShortcutDialog() {
    String label = '';
    String keysInput = '';
    showDialog(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          backgroundColor: theme.colorScheme.surface,
          title: Text('Add Shortcut', style: TextStyle(color: theme.textTheme.bodyLarge?.color)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                style: TextStyle(color: theme.textTheme.bodyLarge?.color),
                decoration: const InputDecoration(labelText: 'Label (e.g. Undo)'),
                onChanged: (val) => label = val,
              ),
              TextField(
                style: TextStyle(color: theme.textTheme.bodyLarge?.color),
                decoration: const InputDecoration(labelText: 'Keys (comma separated, e.g. ctrl,z)'),
                onChanged: (val) => keysInput = val,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (label.isNotEmpty && keysInput.isNotEmpty) {
                  final keysList = keysInput.split(',').map((e) => e.trim().toLowerCase()).toList();
                  setState(() {
                    _shortcuts.add(CustomShortcut(label: label, keys: keysList));
                  });
                  _saveShortcuts();
                }
                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bgColor = theme.scaffoldBackgroundColor.withOpacity(0.95);
    final dividerColor = theme.dividerColor;

    return Container(
      color: bgColor,
      child: Row(
        children: [
          // Left side: Keyboard
          Expanded(
            flex: 3,
            child: Container(
              padding: const EdgeInsets.all(8.0),
              decoration: BoxDecoration(
                border: Border(right: BorderSide(color: dividerColor)),
              ),
              child: _buildKeyboard(),
            ),
          ),
          // Right side: Shortcuts
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Custom Shortcuts',
                        style: TextStyle(color: theme.textTheme.bodyLarge?.color, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        icon: Icon(Icons.add, color: theme.colorScheme.primary),
                        onPressed: _addShortcutDialog,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: GridView.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                        childAspectRatio: 2.5,
                      ),
                      itemCount: _shortcuts.length,
                      itemBuilder: (context, index) {
                        return _buildShortcutButton(context, _shortcuts[index], index);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShortcutButton(BuildContext context, CustomShortcut shortcut, int index) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    
    return InkWell(
      onTap: () => _sendKeyCommand(shortcut.keys),
      onLongPress: () {
        setState(() {
          _shortcuts.removeAt(index);
          _saveShortcuts();
        });
      },
      child: Container(
        decoration: BoxDecoration(
          color: primary.withOpacity(0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: primary.withOpacity(0.4)),
        ),
        alignment: Alignment.center,
        child: Text(
          shortcut.label,
          style: TextStyle(color: theme.textTheme.bodyLarge?.color, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _buildKeyboard() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: Column(
            children: [
              _buildKeyRow(['f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8', 'f9', 'f10', 'f11', 'f12']),
              const SizedBox(height: 6),
              _buildKeyRow(['`', '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 'backspace']),
              const SizedBox(height: 6),
              _buildKeyRow(['tab', 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\\']),
              const SizedBox(height: 6),
              _buildKeyRow(['capslock', 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', 'enter']),
              const SizedBox(height: 6),
              _buildKeyRow(['shift', 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 'up']),
              const SizedBox(height: 6),
              _buildKeyRow(['ctrl', 'win', 'alt', 'space', 'left', 'down', 'right']),
            ],
          ),
        );
      }
    );
  }

  Widget _buildKeyRow(List<String> keys) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: keys.map((k) {
        int flex = 1;
        if (['backspace', 'enter', 'shift', 'capslock'].contains(k)) flex = 2;
        if (k == 'space') flex = 5;
        
        return Expanded(
          flex: flex,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2.0),
            child: _buildKeyButton(k),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildKeyButton(String key) {
    bool isModifier = ['ctrl', 'shift', 'alt', 'win'].contains(key);
    bool isActive = false;
    if (key == 'ctrl') isActive = _ctrlActive;
    if (key == 'shift') isActive = _shiftActive;
    if (key == 'alt') isActive = _altActive;
    if (key == 'win') isActive = _winActive;

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    Color activeBg = theme.colorScheme.primary;
    Color inactiveBg = isDark ? const Color(0xFF2A2A3E) : Colors.grey.shade300;
    Color bgColor = isActive ? activeBg : inactiveBg;
    
    Color activeText = Colors.white;
    Color inactiveText = isDark ? Colors.white70 : Colors.black87;
    Color textColor = isActive ? activeText : inactiveText;
    
    return InkWell(
      onTap: () {
        if (isModifier) {
          setState(() {
            if (key == 'ctrl') _ctrlActive = !_ctrlActive;
            if (key == 'shift') _shiftActive = !_shiftActive;
            if (key == 'alt') _altActive = !_altActive;
            if (key == 'win') _winActive = !_winActive;
          });
        } else {
          _handleKeyPress(key);
        }
      },
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: theme.dividerColor.withOpacity(0.2)),
        ),
        alignment: Alignment.center,
        child: Text(
          key.toUpperCase(),
          style: TextStyle(
            color: textColor, 
            fontSize: key.length > 1 ? 12 : 16,
            fontWeight: isModifier ? FontWeight.bold : FontWeight.normal
          ),
        ),
      ),
    );
  }
}
