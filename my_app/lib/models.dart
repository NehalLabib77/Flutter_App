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


/// Preference profile captured on first launch. It is intentionally small
/// and serialisable so the same shape can be stored locally and sent to the
/// Flask hybrid recommender.
class LearningPreferences {
  final List<String> subjects;
  final List<String> skills;
  final String level;
  final String courseType;
  final String certificateType;
  final String pricePreference;

  const LearningPreferences({
    this.subjects = const [],
    this.skills = const [],
    this.level = '',
    this.courseType = '',
    this.certificateType = '',
    this.pricePreference = '',
  });

  bool get isEmpty =>
      subjects.isEmpty &&
      skills.isEmpty &&
      level.isEmpty &&
      courseType.isEmpty &&
      certificateType.isEmpty &&
      pricePreference.isEmpty;

  Map<String, dynamic> toJson() => {
    'subjects': subjects,
    'skills': skills,
    'level': level,
    'course_type': courseType,
    'certificate_type': certificateType,
    'price_preference': pricePreference,
    // EduCompass is the app-facing catalogue owner after the dataset
    // normalisation requested for this project.
    'provider': 'EduCompass',
    'organization': 'EduCompass',
  };

  Map<String, dynamic> toQueryParameters() => {
    if (subjects.isNotEmpty) 'subjects': subjects.join('|'),
    if (skills.isNotEmpty) 'skills': skills.join('|'),
    if (level.isNotEmpty) 'level': level,
    if (courseType.isNotEmpty) 'course_type': courseType,
    if (certificateType.isNotEmpty) 'certificate_type': certificateType,
    if (pricePreference.isNotEmpty) 'price_preference': pricePreference,
    'provider': 'EduCompass',
    'organization': 'EduCompass',
  };

  factory LearningPreferences.fromJson(Map<String, dynamic> json) {
    List<String> listValue(dynamic value) {
      if (value is List) {
        return value
            .map((item) => item.toString().trim())
            .where((item) => item.isNotEmpty)
            .toList();
      }
      if (value is String && value.trim().isNotEmpty) {
        final separator = value.contains('|') ? '|' : ',';
        return value
            .split(separator)
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toList();
      }
      return const [];
    }

    return LearningPreferences(
      subjects: listValue(json['subjects'] ?? json['preferred_subjects']),
      skills: listValue(json['skills'] ?? json['preferred_skills']),
      level: (json['level'] ?? json['preferred_level'] ?? '').toString(),
      courseType:
          (json['course_type'] ?? json['preferred_course_type'] ?? '')
              .toString(),
      certificateType:
          (json['certificate_type'] ?? json['preferred_certificate_type'] ?? '')
              .toString(),
      pricePreference: (json['price_preference'] ?? '').toString(),
    );
  }
}

/// One completed enrollment shown in Profile -> Order history.
///
/// The backend builds this from the existing Enrollment + Payment rows, so
/// there is no second order database to keep in sync.
class OrderHistoryItem {
  final String courseId;
  final Course? course;
  final String transactionId;
  final String paymentMethod;
  final String paymentStatus;
  final String? amount;
  final String currency;
  final bool validated;
  final bool enrollmentCompleted;
  final String? cardType;
  final String? bankTransactionId;
  final DateTime? enrolledAt;
  final DateTime? updatedAt;

  const OrderHistoryItem({
    required this.courseId,
    this.course,
    required this.transactionId,
    required this.paymentMethod,
    required this.paymentStatus,
    this.amount,
    this.currency = 'BDT',
    this.validated = false,
    this.enrollmentCompleted = false,
    this.cardType,
    this.bankTransactionId,
    this.enrolledAt,
    this.updatedAt,
  });

  factory OrderHistoryItem.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic value) {
      final text = value?.toString().trim() ?? '';
      return text.isEmpty ? null : DateTime.tryParse(text);
    }

    final courseRaw = json['course'];
    return OrderHistoryItem(
      courseId: (json['course_id'] ?? '').toString(),
      course: courseRaw is Map
          ? Course.fromJson(courseRaw.cast<String, dynamic>())
          : null,
      transactionId: (json['transaction_id'] ?? '').toString(),
      paymentMethod: (json['payment_method'] ?? 'EduCompass').toString(),
      paymentStatus: (json['payment_status'] ?? json['status'] ?? '').toString(),
      amount: json['amount']?.toString(),
      currency: (json['currency'] ?? 'BDT').toString(),
      validated: json['validated'] == true,
      enrollmentCompleted: json['enrollment_completed'] == true,
      cardType: json['card_type']?.toString(),
      bankTransactionId: json['bank_transaction_id']?.toString(),
      enrolledAt: parseDate(json['enrolled_at']),
      updatedAt: parseDate(json['updated_at']),
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

/// Response from `POST /payments/sslcommerz/session`. Tells the client
/// which gateway URL to open and which transaction id to bind the
/// deep-link return to.
///
/// **Gateway URL field naming:** the SSLCOMMERZ API returns the URL
/// under several casings (`GatewayPageURL`, `gateway_url`,
/// `gateway_page_url`, etc.). We normalise on [gatewayUrl] (a getter
/// over [gatewayPageUrl]) so callers don't have to remember which
/// casing the current backend version emitted. The original field is
/// retained for backwards compatibility with older deserialisation
/// code that used `gatewayPageUrl` directly.
class SslCommerzSession {
  SslCommerzSession({
    required this.transactionId,
    required this.gatewayPageUrl,
    this.status,
    this.provider,
    this.sessionKey,
    this.currency,
    this.amount,
    this.courseId,
    this.mode,
  });

  final String transactionId;
  final String gatewayPageUrl;
  final String? status;
  final String? provider;
  final String? sessionKey;
  final String? currency;
  final double? amount;
  final String? courseId;

  /// `'sandbox'` or `'live'`. Reflects which SSLCOMMERZ environment
  /// minted this transaction. May be `null` for older backend versions
  /// that did not include the field; callers should treat `null` as
  /// "unknown" rather than defaulting to a particular environment.
  final String? mode;

  /// Preferred name from the user-facing contract; identical to
  /// [gatewayPageUrl] (kept under both names so existing callers and
  /// new ones stay consistent).
  String get gatewayUrl => gatewayPageUrl;

  factory SslCommerzSession.fromJson(Map<String, dynamic> json) {
    final session = (json['session'] as Map?)?.cast<String, dynamic>() ?? json;
    String pickUrl(Map<String, dynamic> m) {
      // SSLCOMMERZ uses several casings depending on the API version.
      // Try them in order so older backends still work.
      const candidates = [
        'gateway_url',
        'gatewayPageURL',
        'GatewayPageURL',
        'gateway_page_url',
        'redirectGatewayURL',
        'redirect_url',
      ];
      for (final key in candidates) {
        final v = m[key];
        if (v != null && v.toString().isNotEmpty) return v.toString();
      }
      return '';
    }

    String? pickMode(Map<String, dynamic> m) {
      // The backend may expose the SSLCOMMERZ mode under any of
      // these keys depending on version. We normalise to lower-case
      // so callers can compare against `'sandbox'` / `'live'` without
      // case-folding the result themselves.
      for (final key in const ['mode', 'payment_mode', 'paymentMode']) {
        final v = m[key];
        if (v != null) {
          final s = v.toString().trim();
          if (s.isNotEmpty) return s.toLowerCase();
        }
      }
      return null;
    }

    double? parseAmount(Object? raw) {
      if (raw == null) return null;
      if (raw is num) return raw.toDouble();
      return double.tryParse(raw.toString().trim().replaceAll(',', ''));
    }

    return SslCommerzSession(
      transactionId:
          (session['transaction_id'] ??
                  session['tran_id'] ??
                  session['session_id'] ??
                  '')
              .toString(),
      gatewayPageUrl: pickUrl(session),
      status: session['status']?.toString(),
      provider: session['provider']?.toString(),
      sessionKey: session['session_key']?.toString(),
      currency: session['currency']?.toString(),
      amount: parseAmount(session['amount']),
      courseId: session['course_id']?.toString(),
      mode: pickMode(session),
    );
  }
}

/// Response from `GET /payments/status/<transaction_id>`. The backend
/// resolves the latest row for the transaction and tells the client
/// whether the payment is `validated`, `failed`, `cancelled`, etc.
///
/// **Source of truth:** the backend status endpoint is authoritative
/// for the payment outcome. The deep-link redirect is only a UX hint
/// that helps the client know when to start polling — it must never
/// be trusted on its own. Callers should always gate enrollment on
/// [isValid] / [isFailure] rather than on the raw [status] string.
class SslCommerzPaymentStatus {
  SslCommerzPaymentStatus({
    required this.transactionId,
    required this.status,
    this.amount,
    this.currency,
    this.paymentMethod,
    this.enrolled = false,
    this.enrollmentStatus,
    this.validated = false,
    this.enrollmentCompleted = false,
    this.courseId,
    this.cardType,
    this.bankTransactionId,
    this.riskLevel,
    this.riskTitle,
    this.updatedAt,
  });

  final String transactionId;
  final String status;
  final double? amount;
  final String? currency;

  /// Coarse payment method label (e.g. `'VISA'`, `'bKash'`,
  /// `'Nagad'`). For finer-grained card / wallet detail prefer
  /// [cardType] when present.
  final String? paymentMethod;
  final bool enrolled;
  final String? enrollmentStatus;
  final bool validated;
  final bool enrollmentCompleted;

  /// Course the payment is bound to. Returned by the backend under
  /// `course_id`. May be `null` for older status rows.
  final String? courseId;

  /// Specific card / instrument brand reported by SSLCOMMERZ
  /// (`'VISA'`, `'MASTERCARD'`, etc.). Distinct from [paymentMethod]
  /// which carries the broader channel label.
  final String? cardType;

  /// Bank-side transaction reference returned by the gateway. Used
  /// for dispute / reconciliation flows; never sent back to the
  /// backend from the client.
  final String? bankTransactionId;

  /// Numeric risk score. `0` = safe; higher values indicate the
  /// gateway wants manual review. Parsed safely: a missing or
  /// non-numeric value leaves this `null`.
  final int? riskLevel;

  /// Human-readable risk verdict (e.g. `'Safe'`, `'High'`).
  final String? riskTitle;

  /// When the status row was last updated server-side. Parsed from
  /// an ISO-8601 string. A `null` value means the backend did not
  /// expose the timestamp.
  final DateTime? updatedAt;

  String get normalizedStatus => status.toUpperCase();

  bool get isValid => normalizedStatus == 'VALIDATED' && enrollmentCompleted;

  bool get isReviewRequired => normalizedStatus == 'REVIEW_REQUIRED';

  bool get isPending => normalizedStatus == 'PENDING';

  bool get isFailure =>
      normalizedStatus == 'FAILED' ||
      normalizedStatus == 'CANCELLED' ||
      normalizedStatus == 'VALIDATION_FAILED';

  factory SslCommerzPaymentStatus.fromJson(Map<String, dynamic> json) {
    final payment = (json['payment'] as Map?)?.cast<String, dynamic>() ?? json;

    // `risk_level` is sometimes a string ('0') in gateway payloads
    // and sometimes a JSON number. Coerce both safely.
    int? parseRiskLevel(Object? raw) {
      if (raw == null) return null;
      if (raw is int) return raw;
      if (raw is num) return raw.toInt();
      return int.tryParse(raw.toString().trim());
    }

    DateTime? parseUpdatedAt(Object? raw) {
      if (raw == null) return null;
      final s = raw.toString().trim();
      if (s.isEmpty) return null;
      return DateTime.tryParse(s);
    }

    double? parseAmount(Object? raw) {
      if (raw == null) return null;
      if (raw is num) return raw.toDouble();
      return double.tryParse(raw.toString().trim().replaceAll(',', ''));
    }

    return SslCommerzPaymentStatus(
      transactionId:
          (payment['transaction_id'] ??
                  payment['tran_id'] ??
                  json['transaction_id'] ??
                  '')
              .toString(),
      status: (payment['status'] ?? json['status'] ?? 'pending').toString(),
      amount: parseAmount(payment['amount']),
      currency: payment['currency']?.toString(),
      paymentMethod: payment['payment_method']?.toString(),
      enrolled: payment['enrolled'] == true || json['enrolled'] == true,
      enrollmentStatus:
          (payment['enrollment_status'] ?? json['enrollment_status'])
              ?.toString(),
      validated: payment['validated'] == true || json['validated'] == true,
      enrollmentCompleted:
          payment['enrollment_completed'] == true ||
          json['enrollment_completed'] == true,
      courseId: (payment['course_id'] ?? json['course_id'])?.toString(),
      cardType: (payment['card_type'] ?? json['card_type'])?.toString(),
      bankTransactionId:
          (payment['bank_transaction_id'] ?? json['bank_transaction_id'])
              ?.toString(),
      riskLevel: parseRiskLevel(payment['risk_level'] ?? json['risk_level']),
      riskTitle: (payment['risk_title'] ?? json['risk_title'])?.toString(),
      updatedAt: parseUpdatedAt(payment['updated_at'] ?? json['updated_at']),
    );
  }
}
