/// Plain data classes that mirror the Flask API payloads.
///
/// Each class has a `fromJson` constructor that tolerates missing keys so the
/// app stays usable when the backend evolves.
library;

class Course {
  final String id;
  final String name;
  final String? description;
  final String? provider;
  final String? subject;
  final String? level;
  final String? url;
  final String? imageUrl;
  final double? rating;
  final int? reviewsCount;
  final int? studentsEnrolled;
  final String? price;
  final bool isFree;
  final List<String> skills;
  final double? similarityScore;
  final double? finalScore;
  final List<String> reasons;

  const Course({
    required this.id,
    required this.name,
    this.description,
    this.provider,
    this.subject,
    this.level,
    this.url,
    this.imageUrl,
    this.rating,
    this.reviewsCount,
    this.studentsEnrolled,
    this.price,
    this.isFree = false,
    this.skills = const [],
    this.similarityScore,
    this.finalScore,
    this.reasons = const [],
  });

  factory Course.fromJson(Map<String, dynamic> json) {
    final id = (json['course_id'] ?? json['id'] ?? '').toString();
    final name = (json['course_name'] ?? json['name'] ?? '').toString();
    final skillsField = json['skills'];
    final skills = skillsField is String
        ? skillsField
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList()
        : (skillsField is List
              ? skillsField.map((s) => s.toString()).toList()
              : <String>[]);
    final isFreeRaw = json['is_free'];
    final price = (json['price'] ?? '').toString().toLowerCase();
    return Course(
      id: id,
      name: name,
      description: json['description']?.toString(),
      provider: json['provider']?.toString(),
      subject: json['subject']?.toString(),
      level: json['level']?.toString(),
      url: json['url']?.toString(),
      imageUrl: json['image_url']?.toString(),
      rating: (json['rating'] as num?)?.toDouble(),
      reviewsCount: (json['reviews_count'] as num?)?.toInt(),
      studentsEnrolled: (json['students_enrolled'] as num?)?.toInt(),
      price: json['price']?.toString(),
      isFree:
          (isFreeRaw is num && isFreeRaw == 1) ||
          isFreeRaw == true ||
          price == 'free',
      skills: skills,
      similarityScore: (json['similarity_score'] as num?)?.toDouble(),
      finalScore: (json['final_score'] as num?)?.toDouble(),
      reasons: ((json['reasons'] as List?) ?? const [])
          .map((s) => s.toString())
          .toList(),
    );
  }
}

class AppUser {
  final int id;
  final String fullName;
  final String email;
  final List<String> interests;

  const AppUser({
    required this.id,
    required this.fullName,
    required this.email,
    this.interests = const [],
  });

  String get initials {
    final parts = fullName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  factory AppUser.fromJson(Map<String, dynamic> json) {
    final interestsRaw = json['interests'];
    final interests = interestsRaw is List
        ? interestsRaw.map((e) => e.toString()).toList()
        : <String>[];
    return AppUser(
      id: (json['id'] as num?)?.toInt() ?? 0,
      fullName: (json['full_name'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      interests: interests,
    );
  }
}

class LearningPathStep {
  final String id;
  final String title;
  final String? description;
  final List<String> courseIds;

  const LearningPathStep({
    required this.id,
    required this.title,
    this.description,
    this.courseIds = const [],
  });

  factory LearningPathStep.fromJson(Map<String, dynamic> json) {
    final courses =
        (json['course_ids'] as List?) ?? (json['courses'] as List?) ?? const [];
    return LearningPathStep(
      id: (json['id'] ?? json['step_id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      description: json['description']?.toString(),
      courseIds: courses.map((c) => c.toString()).toList(),
    );
  }
}

class LearningPath {
  final String id;
  final String title;
  final String? description;
  final List<LearningPathStep> steps;

  const LearningPath({
    required this.id,
    required this.title,
    this.description,
    this.steps = const [],
  });

  factory LearningPath.fromJson(Map<String, dynamic> json) {
    final rawSteps = (json['steps'] as List?) ?? const [];
    return LearningPath(
      id: (json['id'] ?? json['path_id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      description: json['description']?.toString(),
      steps: rawSteps
          .whereType<Map<String, dynamic>>()
          .map(LearningPathStep.fromJson)
          .toList(),
    );
  }
}
