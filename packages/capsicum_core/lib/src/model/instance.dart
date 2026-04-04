import 'user.dart';

class Instance {
  final String name;
  final String? softwareName;
  final String? description;
  final String? iconUrl;
  final String? version;
  final String? themeColor;
  final int? userCount;
  final int? postCount;
  final String? contactEmail;
  final User? contactAccount;
  final String? contactUrl;
  final List<String> rules;
  final String? privacyPolicyUrl;
  final String? statusUrl;

  const Instance({
    required this.name,
    this.softwareName,
    this.description,
    this.iconUrl,
    this.version,
    this.themeColor,
    this.userCount,
    this.postCount,
    this.contactEmail,
    this.contactAccount,
    this.contactUrl,
    this.rules = const [],
    this.privacyPolicyUrl,
    this.statusUrl,
  });
}
