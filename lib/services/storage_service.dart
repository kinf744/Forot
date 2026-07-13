import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../models/server_config.dart';

class StorageService {
  static const _secure = FlutterSecureStorage();
  static const _keyUser = 'user_data';
  static const _keyConfig = 'server_config';

  static Future<void> saveUser(User user) async {
    await _secure.write(key: _keyUser, value: jsonEncode(user.toJson()));
  }

  static Future<User?> getUser() async {
    final data = await _secure.read(key: _keyUser);
    if (data == null) return null;
    return User.fromJson(jsonDecode(data) as Map<String, dynamic>);
  }

  static Future<void> clearUser() async {
    await _secure.delete(key: _keyUser);
  }

  static Future<bool> getBool(String key, {bool defaultValue = false}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key) ?? defaultValue;
  }

  static Future<void> setBool(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  static Future<void> saveServerConfig(ServerConfig config) async {
    await _secure.write(key: _keyConfig, value: jsonEncode(config.toJson()));
  }

  static Future<ServerConfig?> getServerConfig() async {
    final data = await _secure.read(key: _keyConfig);
    if (data == null) return null;
    return ServerConfig.fromJson(jsonDecode(data) as Map<String, dynamic>);
  }

  static Future<void> clearServerConfig() async {
    await _secure.delete(key: _keyConfig);
  }

  static Future<String> getString(String key, {String defaultValue = ''}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key) ?? defaultValue;
  }

  static Future<void> setString(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  static const _keyConfigs = 'configs_list';
  static const _keySelectedIndex = 'selected_config_index';

  static Future<void> saveConfigsList(String jsonData) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyConfigs, jsonData);
  }

  static Future<String> getConfigsList() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyConfigs) ?? '';
  }

  static Future<void> saveSelectedConfigIndex(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keySelectedIndex, index);
  }

  static Future<int?> getSelectedConfigIndex() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keySelectedIndex);
  }

  static Future<void> clearAll() async {
    await _secure.deleteAll();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }
}
