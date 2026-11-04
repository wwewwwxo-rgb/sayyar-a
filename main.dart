// سيّار SAYYAR — تطبيق خرائط وملاحة مجاني للعراق
// الخرائط: OpenStreetMap / CARTO / Esri  •  البحث: Nominatim  •  المسارات: OSRM
// كل شيء مجاني وبدون مفاتيح API.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ════════════════════════════════════════════════════════════════════
//  الألوان والثوابت
// ════════════════════════════════════════════════════════════════════
class C {
  static const bg = Color(0xFF021412);
  static const ink = Color(0xFF031C1A);
  static const panel = Color(0xFF082B28);
  static const panel2 = Color(0xFF0C3A34);
  static const mint = Color(0xFF22E6A0);
  static const mintSoft = Color(0xFF79F2C5);
  static const text = Color(0xFFF2FFFA);
  static const muted = Color(0xFF8FB5AB);
  static const blue = Color(0xFF1E88FF);
  static const danger = Color(0xFFFF5A5F);
}

const LatLng kBaghdad = LatLng(33.3152, 44.3661);
const String kUserAgent = 'SayyarIraq/1.0 (Flutter navigation app)';

class MapStyle {
  const MapStyle(this.name, this.icon, this.url, this.subs, this.credit,
      {this.retina = false, this.maxZoom = 19});
  final String name;
  final IconData icon;
  final String url;
  final List<String> subs;
  final String credit;
  final bool retina;
  final int maxZoom;
}

const List<MapStyle> kMapStyles = [
  MapStyle('ليلية', Icons.dark_mode,
      'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
      ['a', 'b', 'c', 'd'], '© OpenStreetMap © CARTO',
      retina: true),
  MapStyle('شوارع واضحة', Icons.map,
      'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',
      ['a', 'b', 'c', 'd'], '© OpenStreetMap © CARTO',
      retina: true),
  MapStyle('OpenStreetMap', Icons.public,
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png', [], '© OpenStreetMap'),
  MapStyle(
      'أقمار صناعية',
      Icons.satellite_alt,
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      [],
      '© Esri, Maxar, Earthstar',
      maxZoom: 18),
];

class ReportType {
  const ReportType(this.id, this.label, this.icon, this.color);
  final String id;
  final String label;
  final IconData icon;
  final Color color;
}

const List<ReportType> kReportTypes = [
  ReportType('accident', 'حادث', Icons.car_crash, Color(0xFFFF4D4F)),
  ReportType('jam', 'ازدحام', Icons.traffic, Color(0xFFFF9A3C)),
  ReportType('works', 'أعمال طرق', Icons.construction, Color(0xFFFFC53D)),
  ReportType('closure', 'إغلاق طريق', Icons.block, Color(0xFFFF6B3D)),
  ReportType('hazard', 'خطر على الطريق', Icons.warning_amber, Color(0xFFF5E050)),
  ReportType('other', 'أخرى', Icons.more_horiz, C.mint),
];

ReportType reportTypeOf(String id) =>
    kReportTypes.firstWhere((t) => t.id == id, orElse: () => kReportTypes.last);

// ════════════════════════════════════════════════════════════════════
//  النماذج
// ════════════════════════════════════════════════════════════════════
class Place {
  const Place(this.name, this.subtitle, this.point);
  final String name;
  final String subtitle;
  final LatLng point;

  Map<String, dynamic> toJson() => {
        'n': name,
        's': subtitle,
        'la': point.latitude,
        'lo': point.longitude,
      };

  factory Place.fromJson(Map<String, dynamic> j) => Place(
        j['n'] as String,
        j['s'] as String,
        LatLng((j['la'] as num).toDouble(), (j['lo'] as num).toDouble()),
      );
}

class RouteStep {
  RouteStep({
    required this.instruction,
    required this.road,
    required this.distance,
    required this.at,
    required this.type,
    required this.modifier,
  });
  final String instruction;
  final String road;
  double distance; // متر، من هذه المناورة حتى التي تليها
  final LatLng at;
  final String type;
  final String modifier;
}

class RouteOption {
  RouteOption({
    required this.points,
    required this.distance,
    required this.duration,
    required this.steps,
    this.label = 'مسار',
  });
  final List<LatLng> points;
  final double distance; // متر
  final double duration; // ثانية
  final List<RouteStep> steps;
  String label;
}

class Report {
  Report({
    required this.id,
    required this.type,
    required this.point,
    required this.time,
    this.note = '',
  });
  final String id;
  final String type;
  final LatLng point;
  final DateTime time;
  final String note;

  Map<String, dynamic> toJson() => {
        'id': id,
        't': type,
        'la': point.latitude,
        'lo': point.longitude,
        'ms': time.millisecondsSinceEpoch,
        'note': note,
      };

  factory Report.fromJson(Map<String, dynamic> j) => Report(
        id: j['id'] as String,
        type: j['t'] as String,
        point: LatLng((j['la'] as num).toDouble(), (j['lo'] as num).toDouble()),
        time: DateTime.fromMillisecondsSinceEpoch(j['ms'] as int),
        note: (j['note'] ?? '') as String,
      );
}

enum Phase { idle, loading, preview, navigating, arrived }

// ════════════════════════════════════════════════════════════════════
//  أدوات التنسيق
// ════════════════════════════════════════════════════════════════════
String fmtDist(double m) {
  if (m < 1000) {
    final r = m < 100 ? m.round() : (m / 10).round() * 10;
    return '$r م';
  }
  return '${(m / 1000).toStringAsFixed(m < 10000 ? 1 : 0)} كم';
}

String fmtDur(double s) {
  final m = (s / 60).round();
  if (m < 1) return 'أقل من دقيقة';
  if (m < 60) return '$m د';
  final h = m ~/ 60;
  final mm = m % 60;
  return mm == 0 ? '$h س' : '$h س $mm د';
}

String fmtTime(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m ${t.hour < 12 ? 'ص' : 'م'}';
}

String fmtAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'الآن';
  if (d.inMinutes < 60) return 'قبل ${d.inMinutes} د';
  return 'قبل ${d.inHours} س';
}

String spokenDist(double m) {
  if (m >= 1000) return '${(m / 1000).toStringAsFixed(1)} كيلومتر';
  final r = m >= 200 ? (m / 50).round() * 50 : (m / 10).round() * 10;
  return '$r متر';
}

String _turnPhrase(String m) {
  switch (m) {
    case 'right':
      return 'انعطف يميناً';
    case 'left':
      return 'انعطف يساراً';
    case 'slight right':
      return 'انحرف قليلاً إلى اليمين';
    case 'slight left':
      return 'انحرف قليلاً إلى اليسار';
    case 'sharp right':
      return 'انعطف بشدة إلى اليمين';
    case 'sharp left':
      return 'انعطف بشدة إلى اليسار';
    case 'uturn':
      return 'استدر للخلف';
    default:
      return 'استمر للأمام';
  }
}

String buildInstruction(String type, String mod, String road, int? exit) {
  final on = road.isEmpty ? '' : ' على $road';
  switch (type) {
    case 'depart':
      return 'انطلق$on';
    case 'arrive':
      if (mod.contains('left')) return 'وصلت إلى وجهتك، وهي على يسارك';
      if (mod.contains('right')) return 'وصلت إلى وجهتك، وهي على يمينك';
      return 'وصلت إلى وجهتك';
    case 'roundabout':
    case 'rotary':
    case 'roundabout turn':
      return exit != null
          ? 'ادخل الدوّار وخذ المخرج رقم $exit'
          : 'ادخل الدوّار';
    case 'exit roundabout':
    case 'exit rotary':
      return 'اخرج من الدوّار$on';
    case 'merge':
      return 'اندمج مع الطريق$on';
    case 'on ramp':
    case 'off ramp':
      return 'اسلك المنحدر ${mod.contains('left') ? 'الأيسر' : mod.contains('right') ? 'الأيمن' : ''}$on'
          .trim();
    case 'fork':
      if (mod.contains('left')) return 'عند التفرّع خذ المسار الأيسر$on';
      if (mod.contains('right')) return 'عند التفرّع خذ المسار الأيمن$on';
      return 'عند التفرّع استمر للأمام';
    case 'end of road':
      return 'عند نهاية الطريق ${_turnPhrase(mod)}$on';
    default:
      return '${_turnPhrase(mod)}$on';
  }
}

IconData maneuverIcon(String type, String mod) {
  if (type == 'arrive') return Icons.flag;
  if (type == 'depart') return Icons.navigation;
  if (type.contains('roundabout') || type.contains('rotary')) {
    return Icons.roundabout_right;
  }
  switch (mod) {
    case 'uturn':
      return Icons.u_turn_left;
    case 'sharp right':
      return Icons.turn_sharp_right;
    case 'right':
      return Icons.turn_right;
    case 'slight right':
      return Icons.turn_slight_right;
    case 'sharp left':
      return Icons.turn_sharp_left;
    case 'left':
      return Icons.turn_left;
    case 'slight left':
      return Icons.turn_slight_left;
    default:
      return Icons.straight;
  }
}

double segmentDistance(LatLng p, LatLng a, LatLng b) {
  const k = 111320.0;
  final cosLat = math.cos(p.latitude * math.pi / 180);
  double x(LatLng l) => (l.longitude - p.longitude) * k * cosLat;
  double y(LatLng l) => (l.latitude - p.latitude) * k;
  final ax = x(a), ay = y(a), bx = x(b), by = y(b);
  final dx = bx - ax, dy = by - ay;
  final len2 = dx * dx + dy * dy;
  double t = len2 == 0 ? 0 : ((-ax) * dx + (-ay) * dy) / len2;
  t = t.clamp(0.0, 1.0).toDouble();
  final cx = ax + t * dx, cy = ay + t * dy;
  return math.sqrt(cx * cx + cy * cy);
}

double distanceToRoute(LatLng p, List<LatLng> pts) {
  if (pts.length < 2) return 0;
  double best = double.infinity;
  for (int i = 0; i < pts.length - 1; i++) {
    final d = segmentDistance(p, pts[i], pts[i + 1]);
    if (d < best) best = d;
  }
  return best;
}

// ════════════════════════════════════════════════════════════════════
//  الخدمات المجانية: البحث (Nominatim) والمسارات (OSRM)
// ════════════════════════════════════════════════════════════════════
class Api {
  static Future<List<Place>> search(String q,
      {LatLng? near, bool nearOnly = false}) async {
    final params = <String, String>{
      'q': q,
      'format': 'jsonv2',
      'limit': '8',
      'accept-language': 'ar',
      'countrycodes': 'iq',
    };
    if (near != null) {
      const d = 0.25;
      params['viewbox'] =
          '${near.longitude - d},${near.latitude + d},${near.longitude + d},${near.latitude - d}';
      if (nearOnly) params['bounded'] = '1';
    }
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', params);
    final res = await http.get(uri, headers: {
      'User-Agent': kUserAgent,
      'Accept-Language': 'ar',
    }).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception('search ${res.statusCode}');
    final list = jsonDecode(utf8.decode(res.bodyBytes)) as List<dynamic>;
    final out = <Place>[];
    for (final raw in list) {
      final it = raw as Map<String, dynamic>;
      final lat = double.tryParse('${it['lat']}');
      final lon = double.tryParse('${it['lon']}');
      if (lat == null || lon == null) continue;
      final display = (it['display_name'] ?? '') as String;
      final parts = display.split(',').map((e) => e.trim()).toList();
      final nm = ((it['name'] ?? '') as String).trim();
      final name = nm.isNotEmpty ? nm : (parts.isNotEmpty ? parts.first : 'مكان');
      final sub = parts.skip(1).take(3).join('، ');
      out.add(Place(name, sub, LatLng(lat, lon)));
    }
    return out;
  }

  static Future<List<RouteOption>> routes(LatLng from, LatLng to) async {
    Future<http.Response> call(String alt) {
      final uri = Uri.parse(
          'https://router.project-osrm.org/route/v1/driving/${from.longitude},${from.latitude};${to.longitude},${to.latitude}'
          '?overview=full&geometries=geojson&steps=true&alternatives=$alt');
      return http.get(uri, headers: {'User-Agent': kUserAgent}).timeout(
          const Duration(seconds: 20));
    }

    var res = await call('3');
    if (res.statusCode != 200) res = await call('true');
    if (res.statusCode != 200) throw Exception('route ${res.statusCode}');
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (data['code'] != 'Ok') throw Exception('route ${data['code']}');

    final out = <RouteOption>[];
    for (final rr in (data['routes'] as List<dynamic>)) {
      final route = rr as Map<String, dynamic>;
      final coords = (route['geometry'] as Map<String, dynamic>)['coordinates']
          as List<dynamic>;
      final points = coords
          .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
          .toList();

      final steps = <RouteStep>[];
      for (final legRaw in (route['legs'] as List<dynamic>)) {
        final leg = legRaw as Map<String, dynamic>;
        final legSteps = leg['steps'] as List<dynamic>;
        for (int i = 0; i < legSteps.length; i++) {
          final s = legSteps[i] as Map<String, dynamic>;
          final m = s['maneuver'] as Map<String, dynamic>;
          final loc = m['location'] as List<dynamic>;
          final type = ((m['type'] ?? '') as String);
          final mod = ((m['modifier'] ?? '') as String);
          final name = ((s['name'] ?? '') as String);
          final exit = m['exit'] is int ? m['exit'] as int : null;
          final dist = (s['distance'] as num).toDouble();
          final isLast = i == legSteps.length - 1;
          final minor = (type == 'new name' ||
                  type == 'continue' ||
                  type == 'notification') &&
              (mod == 'straight' || mod.isEmpty);
          if (minor && !isLast && steps.isNotEmpty) {
            steps.last.distance += dist; // ندمج المناورات غير المهمة
            continue;
          }
          steps.add(RouteStep(
            instruction: buildInstruction(type, mod, name, exit),
            road: name,
            distance: dist,
            at: LatLng((loc[1] as num).toDouble(), (loc[0] as num).toDouble()),
            type: type,
            modifier: mod,
          ));
        }
      }
      out.add(RouteOption(
        points: points,
        distance: (route['distance'] as num).toDouble(),
        duration: (route['duration'] as num).toDouble(),
        steps: steps,
      ));
    }
    if (out.isEmpty) throw Exception('no routes');
    final minDist = out.map((r) => r.distance).reduce(math.min);
    for (int i = 0; i < out.length; i++) {
      if (i == 0) {
        out[i].label = 'الأسرع';
      } else if (out[i].distance <= minDist + 1) {
        out[i].label = 'الأقصر';
      } else {
        out[i].label = 'مسار بديل';
      }
    }
    return out;
  }
}

// ════════════════════════════════════════════════════════════════════
//  العقل المركزي للتطبيق
// ════════════════════════════════════════════════════════════════════
class SayyarCore extends ChangeNotifier {
  final MapController map = MapController();
  final FlutterTts _tts = FlutterTts();
  late SharedPreferences _prefs;
  StreamSubscription<Position>? _sub;
  void Function(String)? toast;
  bool _mapReady = false;
  bool _disposed = false;

  // واجهة
  int tab = 0;
  Phase phase = Phase.idle;
  bool follow = true;

  // الموقع
  LatLng? me;
  double heading = 0;
  double speedKmh = 0;
  String? locationMsg;
  bool _firstFix = true;

  // المسار
  Place? dest;
  List<RouteOption> routes = [];
  int selected = 0;
  String? routeError;
  int stepIndex = 0;
  double distToNext = 0;
  double remDist = 0;
  double remSecs = 0;
  int _stage = 0;
  bool _rerouting = false;
  DateTime _lastReroute = DateTime.fromMillisecondsSinceEpoch(0);

  // البيانات
  Place? home;
  Place? work;
  List<Place> saved = [];
  List<Place> recents = [];
  List<Report> reports = [];

  // الإعدادات
  bool voice = true;
  bool keepAwake = true;
  bool showReports = true;
  int styleIndex = 1;
  int trips = 0;
  double totalKm = 0;

  MapStyle get style => kMapStyles[styleIndex.clamp(0, kMapStyles.length - 1)];
  RouteOption? get route => routes.isEmpty ? null : routes[selected];
  RouteStep? get nextStep {
    final r = route;
    if (r == null || r.steps.isEmpty) return null;
    return r.steps[math.min(stepIndex + 1, r.steps.length - 1)];
  }

  void _n() {
    if (!_disposed) notifyListeners();
  }

  void say(String m) => toast?.call(m);

  // ── التهيئة ─────────────────────────────────────────────────────
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _load();
    try {
      await _tts.setLanguage('ar');
      await _tts.setSpeechRate(0.47);
    } catch (_) {}
    startLocation();
  }

  void _load() {
    home = _readPlace('home');
    work = _readPlace('work');
    saved = _readPlaces('saved');
    recents = _readPlaces('recents');
    voice = _prefs.getBool('voice') ?? true;
    keepAwake = _prefs.getBool('awake') ?? true;
    showReports = _prefs.getBool('showReports') ?? true;
    styleIndex = _prefs.getInt('style') ?? 1;
    trips = _prefs.getInt('trips') ?? 0;
    totalKm = _prefs.getDouble('km') ?? 0;
    final raw = _prefs.getString('reports');
    if (raw != null) {
      try {
        reports = (jsonDecode(raw) as List<dynamic>)
            .map((e) => Report.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        reports = [];
      }
    }
    _pruneReports();
  }

  Place? _readPlace(String k) {
    final s = _prefs.getString(k);
    if (s == null) return null;
    try {
      return Place.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  List<Place> _readPlaces(String k) {
    final s = _prefs.getString(k);
    if (s == null) return [];
    try {
      return (jsonDecode(s) as List<dynamic>)
          .map((e) => Place.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  void _writePlaces(String k, List<Place> l) =>
      _prefs.setString(k, jsonEncode(l.map((e) => e.toJson()).toList()));

  void _saveReports() => _prefs.setString(
      'reports', jsonEncode(reports.map((e) => e.toJson()).toList()));

  void _pruneReports() => reports.removeWhere(
      (r) => DateTime.now().difference(r.time) > const Duration(hours: 8));

  // ── الموقع ──────────────────────────────────────────────────────
  Future<void> startLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        locationMsg = 'فعّل خدمة الموقع (GPS) في هاتفك';
        _n();
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        locationMsg = 'نحتاج إذن الموقع لتحديد مكانك وتشغيل الملاحة';
        _n();
        return;
      }
      locationMsg = null;
      await _lastKnown();
      await _sub?.cancel();
      _sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 3,
        ),
      ).listen(_onPosition, onError: (_) {
        locationMsg = 'تعذر قراءة الموقع حالياً';
        _n();
      });
      _n();
    } catch (_) {
      locationMsg = 'تعذر تحديد الموقع حالياً';
      _n();
    }
  }

  Future<void> _lastKnown() async {
    try {
      final p = await Geolocator.getLastKnownPosition();
      if (p != null) _onPosition(p);
    } catch (_) {}
  }

  void _onPosition(Position p) {
    final here = LatLng(p.latitude, p.longitude);
    me = here;
    final sp = (p.speed.isFinite && p.speed > 0) ? p.speed : 0.0;
    speedKmh = sp * 3.6;
    if (p.heading.isFinite && p.heading >= 0 && sp > 1.2) heading = p.heading;
    locationMsg = null;
    if (_firstFix) {
      _firstFix = false;
      moveTo(here, 15);
    }
    if (phase == Phase.navigating) {
      _updateNav();
      if (follow && phase == Phase.navigating) _follow(here);
    }
    _n();
  }

  // ── الخريطة ─────────────────────────────────────────────────────
  void onMapReady() {
    _mapReady = true;
    final p = me;
    if (p != null) moveTo(p, 15);
  }

  void moveTo(LatLng p, double z) {
    if (!_mapReady) return;
    try {
      map.move(p, z);
    } catch (_) {}
  }

  void zoomBy(double d) {
    if (!_mapReady) return;
    try {
      final c = map.camera;
      map.move(c.center, (c.zoom + d).clamp(3.0, 19.0).toDouble());
    } catch (_) {}
  }

  void _follow(LatLng p) {
    if (!_mapReady) return;
    try {
      map.moveAndRotate(p, 17.5, -heading);
    } catch (_) {}
  }

  void fitRoute() {
    if (!_mapReady || routes.isEmpty) return;
    try {
      map.fitCamera(CameraFit.coordinates(
        coordinates: routes[selected].points,
        padding: const EdgeInsets.fromLTRB(40, 150, 40, 420),
        maxZoom: 17,
      ));
    } catch (_) {}
  }

  void recenter() {
    follow = true;
    final p = me;
    if (p == null) {
      startLocation();
      return;
    }
    if (phase == Phase.navigating) {
      _follow(p);
    } else {
      moveTo(p, 16);
    }
    _n();
  }

  void userMoved() {
    if (phase == Phase.navigating && follow) {
      follow = false;
      _n();
    }
  }

  void setTab(int i) {
    tab = i;
    _n();
  }

  void focusOn(LatLng p) {
    tab = 0;
    moveTo(p, 16);
    _n();
  }

  // ── الرحلة ──────────────────────────────────────────────────────
  Future<void> goTo(Place p) async {
    if (phase == Phase.navigating) _endNavFx();
    dest = p;
    routes = [];
    selected = 0;
    routeError = null;
    stepIndex = 0;
    _stage = 0;
    phase = Phase.loading;
    tab = 0;
    addRecent(p);
    moveTo(p.point, 14);
    _n();
    await _loadRoutes();
  }

  Future<void> retryRoutes() async {
    phase = Phase.loading;
    routeError = null;
    _n();
    await _loadRoutes();
  }

  Future<void> _loadRoutes() async {
    if (me == null) await _lastKnown();
    final from = me;
    final to = dest;
    if (from == null || to == null) {
      routes = [];
      routeError = 'لم نتمكن من تحديد موقعك. فعّل الـ GPS ثم حاول مجدداً';
      phase = Phase.preview;
      _n();
      return;
    }
    try {
      final list = await Api.routes(from, to.point);
      if (phase != Phase.loading) return; // أُلغيت الرحلة أثناء الانتظار
      routes = list;
      selected = 0;
      routeError = null;
    } catch (_) {
      if (phase != Phase.loading) return;
      routes = [];
      routeError = 'تعذر حساب المسار. تحقق من الإنترنت وحاول مجدداً';
    }
    phase = Phase.preview;
    _n();
    fitRoute();
  }

  void selectRoute(int i) {
    selected = i;
    _n();
    fitRoute();
  }

  Future<void> startNavigation() async {
    if (routes.isEmpty || dest == null) return;
    phase = Phase.navigating;
    follow = true;
    stepIndex = 0;
    _stage = 0;
    _updateNav();
    if (keepAwake) {
      try {
        await WakelockPlus.enable();
      } catch (_) {}
    }
    speak('بدأت الملاحة إلى ${dest!.name}');
    final p = me;
    if (p != null) _follow(p);
    _n();
  }

  void _updateNav() {
    final p = me;
    final r = route;
    if (p == null || r == null) return;
    final steps = r.steps;
    if (steps.length < 2) return;

    if (distanceToRoute(p, r.points) > 80) _reroute();

    final destPt = dest!.point;
    final toDest = Geolocator.distanceBetween(
        p.latitude, p.longitude, destPt.latitude, destPt.longitude);
    if (toDest < 30) {
      _arrive();
      return;
    }

    var next = steps[math.min(stepIndex + 1, steps.length - 1)];
    var d = Geolocator.distanceBetween(
        p.latitude, p.longitude, next.at.latitude, next.at.longitude);
    final threshold = math.max(25.0, speedKmh / 3.6 * 2.5);
    if (d < threshold && stepIndex + 1 < steps.length) {
      if (stepIndex + 1 >= steps.length - 1) {
        _arrive();
        return;
      }
      stepIndex++;
      _stage = 0;
      next = steps[stepIndex + 1];
      d = Geolocator.distanceBetween(
          p.latitude, p.longitude, next.at.latitude, next.at.longitude);
    }
    distToNext = d;

    double rem = d;
    for (int j = stepIndex + 2; j < steps.length; j++) {
      rem += steps[j].distance;
    }
    remDist = rem;
    remSecs = r.distance > 0 ? r.duration * (rem / r.distance) : 0;

    if (d <= 130 && _stage < 2) {
      _stage = 2;
      speak(next.instruction);
    } else if (d <= 550 && _stage < 1) {
      _stage = 1;
      speak('بعد ${spokenDist(d)}، ${next.instruction}');
    }
  }

  Future<void> _reroute() async {
    final here = me;
    final to = dest;
    if (_rerouting || here == null || to == null) return;
    if (DateTime.now().difference(_lastReroute).inSeconds < 12) return;
    _rerouting = true;
    _lastReroute = DateTime.now();
    try {
      final list = await Api.routes(here, to.point);
      if (phase == Phase.navigating && list.isNotEmpty) {
        routes = list;
        selected = 0;
        stepIndex = 0;
        _stage = 0;
        speak('تم إعادة حساب المسار');
      }
    } catch (_) {
    } finally {
      _rerouting = false;
      _n();
    }
  }

  void _arrive() {
    if (phase != Phase.navigating) return;
    phase = Phase.arrived;
    final r = route;
    trips++;
    if (r != null) totalKm += r.distance / 1000;
    _prefs.setInt('trips', trips);
    _prefs.setDouble('km', totalKm);
    speak('وصلت إلى وجهتك');
    _endNavFx();
    _n();
  }

  void _endNavFx() {
    try {
      WakelockPlus.disable();
    } catch (_) {}
    if (_mapReady) {
      try {
        map.rotate(0);
      } catch (_) {}
    }
  }

  void cancelTrip() {
    phase = Phase.idle;
    dest = null;
    routes = [];
    routeError = null;
    stepIndex = 0;
    _endNavFx();
    _tts.stop();
    _n();
  }

  // ── الصوت ───────────────────────────────────────────────────────
  Future<void> speak(String text, {bool force = false}) async {
    if (!voice && !force) return;
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {}
  }

  void toggleVoice() => setVoice(!voice);

  // ── المفضلة ─────────────────────────────────────────────────────
  bool _same(Place a, Place b) =>
      (a.point.latitude - b.point.latitude).abs() < 1e-5 &&
      (a.point.longitude - b.point.longitude).abs() < 1e-5;

  void setHome(Place p) {
    home = p;
    _prefs.setString('home', jsonEncode(p.toJson()));
    _n();
  }

  void setWork(Place p) {
    work = p;
    _prefs.setString('work', jsonEncode(p.toJson()));
    _n();
  }

  void clearHome() {
    home = null;
    _prefs.remove('home');
    _n();
  }

  void clearWork() {
    work = null;
    _prefs.remove('work');
    _n();
  }

  bool isSaved(Place p) => saved.any((s) => _same(s, p));

  void toggleSaved(Place p) {
    if (isSaved(p)) {
      saved.removeWhere((s) => _same(s, p));
      say('تمت الإزالة من المفضلة');
    } else {
      saved.insert(0, p);
      say('تمت الإضافة إلى المفضلة');
    }
    _writePlaces('saved', saved);
    _n();
  }

  void addRecent(Place p) {
    recents.removeWhere((r) => _same(r, p));
    recents.insert(0, p);
    if (recents.length > 8) recents = recents.sublist(0, 8);
    _writePlaces('recents', recents);
  }

  void clearRecents() {
    recents = [];
    _prefs.remove('recents');
    _n();
  }

  // ── البلاغات ────────────────────────────────────────────────────
  void addReport(String type, String note) {
    LatLng? p = me;
    if (p == null && _mapReady) {
      try {
        p = map.camera.center;
      } catch (_) {}
    }
    if (p == null) {
      say('حدد موقعك أولاً');
      return;
    }
    _pruneReports();
    reports.insert(
      0,
      Report(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        type: type,
        point: p,
        time: DateTime.now(),
        note: note,
      ),
    );
    _saveReports();
    say('تم حفظ البلاغ، شكراً لمساهمتك');
    _n();
  }

  void removeReport(String id) {
    reports.removeWhere((r) => r.id == id);
    _saveReports();
    _n();
  }

  // ── الإعدادات ───────────────────────────────────────────────────
  void setVoice(bool v) {
    voice = v;
    _prefs.setBool('voice', v);
    if (!v) _tts.stop();
    _n();
  }

  void setKeepAwake(bool v) {
    keepAwake = v;
    _prefs.setBool('awake', v);
    _n();
  }

  void setShowReports(bool v) {
    showReports = v;
    _prefs.setBool('showReports', v);
    _n();
  }

  void setStyle(int i) {
    styleIndex = i;
    _prefs.setInt('style', i);
    _n();
  }

  Future<void> wipe() async {
    await _prefs.clear();
    home = null;
    work = null;
    saved = [];
    recents = [];
    reports = [];
    trips = 0;
    totalKm = 0;
    voice = true;
    keepAwake = true;
    showReports = true;
    styleIndex = 1;
    say('تم حذف بياناتك المحلية');
    _n();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _tts.stop();
    try {
      WakelockPlus.disable();
    } catch (_) {}
    map.dispose();
    super.dispose();
  }
}

// ════════════════════════════════════════════════════════════════════
//  نقطة البداية والثيم
// ════════════════════════════════════════════════════════════════════
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SayyarApp());
}

class SayyarApp extends StatelessWidget {
  const SayyarApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: C.bg,
      colorScheme: ColorScheme.fromSeed(
        seedColor: C.mint,
        brightness: Brightness.dark,
      ).copyWith(
        primary: C.mint,
        onPrimary: C.ink,
        surface: C.panel,
        onSurface: C.text,
      ),
    );
    final theme = base.copyWith(
      textTheme: GoogleFonts.cairoTextTheme(base.textTheme)
          .apply(bodyColor: C.text, displayColor: C.text),
      appBarTheme: const AppBarTheme(
        backgroundColor: C.bg,
        foregroundColor: C.text,
        elevation: 0,
        centerTitle: true,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: C.panel2,
        contentTextStyle: const TextStyle(color: C.text, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? C.ink : C.muted),
        trackColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? C.mint : C.panel2),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF041F1D),
        indicatorColor: C.mint.withValues(alpha: .18),
        height: 68,
        iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            color: s.contains(WidgetState.selected) ? C.mint : C.muted)),
        labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: s.contains(WidgetState.selected) ? C.mint : C.muted,
            )),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: C.mint,
          foregroundColor: C.ink,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
    );

    return MaterialApp(
      title: 'سيّار',
      debugShowCheckedModeBanner: false,
      theme: theme,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const Root(),
    );
  }
}

class Root extends StatefulWidget {
  const Root({super.key});

  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  final SayyarCore core = SayyarCore();
  bool ready = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await Future.wait([
      core.init(),
      Future<void>.delayed(const Duration(milliseconds: 2300)),
    ]);
    if (mounted) setState(() => ready = true);
  }

  @override
  void dispose() {
    core.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 500),
      child: ready
          ? Shell(key: const ValueKey('shell'), core: core)
          : const SplashScreen(key: ValueKey('splash')),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  شاشة البداية
// ════════════════════════════════════════════════════════════════════
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF07352F), Color(0xFF021412)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 1800),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => Opacity(
                opacity: v.clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 0.85 + 0.15 * v,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const AppLogo(size: 150),
                      const SizedBox(height: 18),
                      const Text('سيّار',
                          style: TextStyle(
                              fontSize: 56,
                              fontWeight: FontWeight.w800,
                              height: 1.1)),
                      const Text('SAYYAR',
                          style: TextStyle(
                              fontSize: 15,
                              letterSpacing: 9,
                              color: C.mint,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 14),
                      const Text('طريقك.. بأمان وأسرع وقت',
                          style: TextStyle(fontSize: 16, color: C.mintSoft)),
                      const SizedBox(height: 38),
                      SizedBox(
                        width: 190,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            minHeight: 5,
                            value: v,
                            color: C.mint,
                            backgroundColor: C.panel2,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text('جارٍ التحميل...',
                          style: TextStyle(fontSize: 12, color: C.muted)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 80});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/icon/avatar.png',
      width: size,
      height: size,
      errorBuilder: (_, __, ___) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: C.panel2,
          borderRadius: BorderRadius.circular(size * .22),
        ),
        child: Icon(Icons.location_on, color: C.mint, size: size * .6),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  الهيكل الرئيسي (التبويبات)
// ════════════════════════════════════════════════════════════════════
class Shell extends StatefulWidget {
  const Shell({super.key, required this.core});
  final SayyarCore core;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  @override
  void initState() {
    super.initState();
    widget.core.toast = _toast;
  }

  void _toast(String msg) {
    if (!mounted) return;
    final sm = ScaffoldMessenger.of(context);
    sm.hideCurrentSnackBar();
    sm.showSnackBar(SnackBar(content: Text(msg, textAlign: TextAlign.center)));
  }

  @override
  Widget build(BuildContext context) {
    final core = widget.core;
    return ListenableBuilder(
      listenable: core,
      builder: (context, _) {
        final hideBar = core.phase == Phase.navigating && core.tab == 0;
        return Scaffold(
          body: IndexedStack(
            index: core.tab,
            children: [
              HomePage(core: core),
              FavoritesPage(core: core),
              ReportsPage(core: core),
              SearchPage(core: core),
              AccountPage(core: core),
            ],
          ),
          bottomNavigationBar: hideBar
              ? null
              : NavigationBar(
                  selectedIndex: core.tab,
                  onDestinationSelected: core.setTab,
                  destinations: const [
                    NavigationDestination(
                        icon: Icon(Icons.home_outlined),
                        selectedIcon: Icon(Icons.home_rounded),
                        label: 'الرئيسية'),
                    NavigationDestination(
                        icon: Icon(Icons.star_border_rounded),
                        selectedIcon: Icon(Icons.star_rounded),
                        label: 'المفضلة'),
                    NavigationDestination(
                        icon: Icon(Icons.campaign_outlined),
                        selectedIcon: Icon(Icons.campaign),
                        label: 'البلاغات'),
                    NavigationDestination(
                        icon: Icon(Icons.search),
                        selectedIcon: Icon(Icons.search),
                        label: 'البحث'),
                    NavigationDestination(
                        icon: Icon(Icons.person_outline),
                        selectedIcon: Icon(Icons.person),
                        label: 'حسابي'),
                  ],
                ),
        );
      },
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  عناصر واجهة مشتركة
// ════════════════════════════════════════════════════════════════════
BoxDecoration cardDeco({double r = 22, Color? color, Color? border}) =>
    BoxDecoration(
      color: color ?? C.panel.withValues(alpha: .97),
      borderRadius: BorderRadius.circular(r),
      border: Border.all(color: border ?? C.mint.withValues(alpha: .20)),
      boxShadow: const [
        BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 6)),
      ],
    );

Widget roundBtn(IconData icon, VoidCallback onTap,
    {Color? fg, Color? bg, double size = 46}) {
  return Material(
    color: bg ?? C.panel.withValues(alpha: .97),
    shape: const CircleBorder(),
    elevation: 4,
    shadowColor: Colors.black54,
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: C.mint.withValues(alpha: .30)),
        ),
        child: Icon(icon, color: fg ?? C.text, size: size * .5),
      ),
    ),
  );
}

class PageHeader extends StatelessWidget {
  const PageHeader(
      {super.key, required this.icon, required this.title, required this.sub});
  final IconData icon;
  final String title;
  final String sub;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
            color: C.panel2, borderRadius: BorderRadius.circular(16)),
        child: Icon(icon, color: C.mint),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          Text(sub, style: const TextStyle(color: C.muted, fontSize: 13)),
        ]),
      ),
    ]);
  }
}

class Tile extends StatelessWidget {
  const Tile({
    super.key,
    required this.icon,
    required this.title,
    this.sub,
    this.onTap,
    this.trailing,
    this.iconColor,
  });
  final IconData icon;
  final String title;
  final String? sub;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: C.panel,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: C.mint.withValues(alpha: .14)),
      ),
      child: ListTile(
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
              color: C.panel2, borderRadius: BorderRadius.circular(14)),
          child: Icon(icon, color: iconColor ?? C.mint),
        ),
        title: Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: sub == null || sub!.isEmpty
            ? null
            : Text(sub!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: C.muted)),
        trailing: trailing ??
            (onTap == null
                ? null
                : const Icon(Icons.chevron_left, color: C.mintSoft)),
      ),
    );
  }
}

Future<Place?> pickPlace(BuildContext context, SayyarCore core) {
  return Navigator.of(context).push<Place>(
    MaterialPageRoute<Place>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('اختر مكاناً')),
        body: SearchPage(core: core, pick: true),
      ),
    ),
  );
}

Future<void> homeWorkAction(
    BuildContext context, SayyarCore core, bool isHome) async {
  final existing = isHome ? core.home : core.work;
  if (existing != null) {
    core.goTo(existing);
    return;
  }
  final p = await pickPlace(context, core);
  if (p == null) return;
  if (isHome) {
    core.setHome(p);
  } else {
    core.setWork(p);
  }
}

// ════════════════════════════════════════════════════════════════════
//  الصفحة الرئيسية (الخريطة + الملاحة)
// ════════════════════════════════════════════════════════════════════
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.core});
  final SayyarCore core;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: core,
      builder: (context, _) {
        final nav = core.phase == Phase.navigating;
        return Stack(children: [
          MapView(core: core),
          SafeArea(
            child: Stack(children: [
              Positioned(
                top: 8,
                left: 12,
                right: 12,
                child: nav ? NavBanner(core: core) : TopBar(core: core),
              ),
              Positioned(
                left: 14,
                top: nav ? 124 : 68,
                child: IgnorePointer(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                        color: const Color(0xAA031C1A),
                        borderRadius: BorderRadius.circular(8)),
                    child: Text(core.style.credit,
                        style: const TextStyle(fontSize: 9, color: Colors.white70)),
                  ),
                ),
              ),
              Positioned(
                right: 12,
                top: nav ? 130 : 84,
                child: MapControls(core: core),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: BottomPanel(core: core),
              ),
            ]),
          ),
        ]);
      },
    );
  }
}

class MapView extends StatelessWidget {
  const MapView({super.key, required this.core});
  final SayyarCore core;

  @override
  Widget build(BuildContext context) {
    final st = core.style;
    final r = core.route;
    return FlutterMap(
      mapController: core.map,
      options: MapOptions(
        initialCenter: kBaghdad,
        initialZoom: 12,
        minZoom: 3,
        maxZoom: 19,
        backgroundColor: C.ink,
        interactionOptions:
            InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
        onMapReady: core.onMapReady,
        onLongPress: (tap, point) => core.goTo(Place(
            'نقطة على الخريطة',
            '${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)}',
            point)),
        onPositionChanged: (camera, hasGesture) {
          if (hasGesture) core.userMoved();
        },
      ),
      children: [
        TileLayer(
          key: ValueKey(st.url),
          urlTemplate: st.url,
          subdomains: st.subs,
          userAgentPackageName: 'com.sayyar.sayyar',
          maxNativeZoom: st.maxZoom,
          retinaMode: st.retina && RetinaMode.isHighDensity(context),
        ),
        if (r != null)
          PolylineLayer(polylines: [
            for (int i = 0; i < core.routes.length; i++)
              if (i != core.selected && core.phase == Phase.preview)
                Polyline(
                  points: core.routes[i].points,
                  strokeWidth: 6,
                  color: const Color(0xFF8DB4AE),
                  borderStrokeWidth: 2,
                  borderColor: Colors.white,
                ),
            Polyline(
              points: r.points,
              strokeWidth: 8,
              color: C.blue,
              borderStrokeWidth: 2.5,
              borderColor: Colors.white,
            ),
          ]),
        MarkerLayer(markers: [
          if (core.showReports)
            for (final rp in core.reports)
              Marker(
                point: rp.point,
                width: 42,
                height: 42,
                child: GestureDetector(
                  onTap: () => showReportSheet(context, core, rp),
                  child: ReportDot(type: rp.type),
                ),
              ),
          if (core.dest != null)
            Marker(
              point: core.dest!.point,
              width: 80,
              height: 80,
              child: const DestPin(),
            ),
          if (core.me != null)
            Marker(
              point: core.me!,
              width: 54,
              height: 54,
              rotate: true,
              child: MeDot(
                heading: core.heading,
                navigating: core.phase == Phase.navigating,
              ),
            ),
        ]),
      ],
    );
  }
}

class MeDot extends StatelessWidget {
  const MeDot({super.key, required this.heading, required this.navigating});
  final double heading;
  final bool navigating;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: C.blue,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
                color: C.blue.withValues(alpha: .5),
                blurRadius: 14,
                spreadRadius: 4),
          ],
        ),
        child: Transform.rotate(
          angle: navigating ? 0 : heading * math.pi / 180,
          child: const Icon(Icons.navigation, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

class DestPin extends StatelessWidget {
  const DestPin({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(children: [
      SizedBox(
        height: 40,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Icon(Icons.location_on, color: C.danger, size: 40),
        ),
      ),
      SizedBox(height: 40),
    ]);
  }
}

class ReportDot extends StatelessWidget {
  const ReportDot({super.key, required this.type});
  final String type;

  @override
  Widget build(BuildContext context) {
    final t = reportTypeOf(type);
    return Center(
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: t.color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 6)],
        ),
        child: Icon(t.icon, color: C.ink, size: 19),
      ),
    );
  }
}

void showReportSheet(BuildContext context, SayyarCore core, Report rp) {
  final t = reportTypeOf(rp.type);
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: C.panel,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            ReportDot(type: rp.type),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.label,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800)),
                    Text(fmtAgo(rp.time),
                        style: const TextStyle(color: C.muted, fontSize: 12)),
                  ]),
            ),
          ]),
          if (rp.note.isNotEmpty) ...[
            const SizedBox(height: 10),
            Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(rp.note)),
          ],
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  core.removeReport(rp.id);
                  Navigator.pop(ctx);
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('حذف البلاغ'),
              ),
            ),
          ]),
        ]),
      ),
    ),
  );
}

class TopBar extends StatelessWidget {
  const TopBar({super.key, required this.core});
  final SayyarCore core;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      roundBtn(
        Icons.menu,
        () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => SettingsPage(core: core))),
        size: 52,
      ),
      const SizedBox(width: 10),
      Expanded(
        child: GestureDetector(
          onTap: () => core.setTab(3),
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: cardDeco(r: 18, border: C.mint.withValues(alpha: .5)),
            child: const Row(children: [
              Icon(Icons.search, color: C.mint),
              SizedBox(width: 10),
              Expanded(
                child: Text('ابحث عن مكان أو عنوان',
                    style: TextStyle(color: C.muted, fontSize: 14)),
              ),
            ]),
          ),
        ),
      ),
    ]);
  }
}

class NavBanner extends StatelessWidget {
  const NavBanner({super.key, required this.core});
  final SayyarCore core;

  @override
  Widget build(BuildContext context) {
    final s = core.nextStep;
    if (s == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xFF0E7A57), Color(0xFF0A5A42)]),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: C.mint.withValues(alpha: .5)),
        boxShadow: const [
          BoxShadow(color: Color(0x88000000), blurRadius: 18, offset: Offset(0, 6))
        ],
      ),
      child: Row(children: [
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
              color: C.ink.withValues(alpha: .55),
              borderRadius: BorderRadius.circular(18)),
          child: Icon(maneuverIcon(s.type, s.modifier), color: Colors.white, size: 40),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(fmtDist(core.distToNext),
                    style: const TextStyle(
                        fontSize: 26, fontWeight: FontWeight.w800, height: 1.1)),
                Text(s.instruction,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, color: Color(0xFFD9FFEF))),
              ]),
        ),
      ]),
    );
  }
}

class MapControls extends StatelessWidget {
  const MapControls({super.key, required this.core});
  final SayyarCore core;

  @override
  Widget build(BuildContext context) {
    final nav = core.phase == Phase.navigating;
    final preview = core.phase == Phase.preview || core.phase == Phase.loading;
    final gap = const SizedBox(height: 8);
    return Column(children: [
      roundBtn(Icons.layers_outlined, () => showLayersSheet(context, core)),
      if (!nav && !preview) ...[
        gap,
        roundBtn(Icons.add, () => core.zoomBy(1)),
        gap,
        roundBtn(Icons.remove, () => core.zoomBy(-1)),
      ],
      gap,
      roundBtn(
        nav && !core.follow ? Icons.navigation : Icons.my_location,
        core.recenter,
        fg: (nav && !core.follow) ? C.ink : C.text,
        bg: (nav && !core.follow) ? C.mint : null,
      ),
      if (!preview) ...[
        gap,
        roundBtn(Icons.add_alert_outlined, () => core.setTab(2), fg: C.mint),
      ],
    ]);
  }
}

void showLayersSheet(BuildContext context, SayyarCore core) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: C.panel,
    showDragHandle: true,
    builder: (ctx) => ListenableBuilder(
      listenable: core,
      builder: (ctx, _) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('نمط الخريطة',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (int i = 0; i < kMapStyles.length; i++)
                  ChoiceChip(
                    avatar: Icon(kMapStyles[i].icon,
                        size: 18,
                        color: core.styleIndex == i ? C.ink : C.mint),
                    label: Text(kMapStyles[i].name),
                    selected: core.styleIndex == i,
                    selectedColor: C.mint,
                    backgroundColor: C.panel2,
                    labelStyle: TextStyle(
                        color: core.styleIndex == i ? C.ink : C.text,
                        fontWeight: FontWeight.w700),
                    onSelected: (_) => core.setStyle(i),
                  ),
              ]),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: core.showReports,
                onChanged: core.setShowReports,
                title: const Text('عرض البلاغات على الخريطة'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// ── اللوحة السفلية حسب الحالة ────────────────────────────────────────
class BottomPanel extends StatelessWidget {
  const BottomPanel({super.key, required this.core});
  final SayyarCore core;

  @override
  Widget build(BuildContext context) {
    switch (core.phase) {
      case Phase.idle:
        return IdlePanel(core: core);
      case Phase.loading:
        return Container(
          padding: const EdgeInsets.all(20),
          decoration: cardDeco(),
          child: Row(children: [
            const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 3, color: C.mint)),
            const SizedBox(width: 14),
            Expanded(
              child: Text('جارٍ حساب أفضل مسار إلى ${core.dest?.name ?? ''}...',
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            IconButton(onPressed: core.cancelTrip, icon: const Icon(Icons.close)),
          ]),
        );
      case Phase.preview:
        return PreviewPanel(core: core);
      case Phase.navigating:
        return NavPanel(core: core);
      case Phase.arrived:
        return Container(
          padding: const EdgeInsets.all(18),
          decoration: cardDeco(),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.flag_circle, color: C.mint, size: 54),
            const SizedBox(height: 6),
            const Text('وصلت إلى وجهتك',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            Text(core.dest?.name ?? '',
                style: const TextStyle(color: C.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 14),
            FilledButton(onPressed: core.cancelTrip, child: const Text('تم')),
          ]),
        );
    }
  }
}

class IdlePanel extends StatelessWidget {
  const IdlePanel({super.key, required this.core});
  final SayyarCore core;

  @override
  Widget build(BuildContext context) {
    Widget chip(IconData icon, String label, String sub, bool isHome) {
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => homeWorkAction(context, core, isHome),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: C.panel2,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: C.mint.withValues(alpha: .15)),
            ),
            child: Row(children: [
              Icon(icon, color: C.mint),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11, color: C.muted)),
                    ]),
              ),
            ]),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: cardDeco(),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (core.locationMsg != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(children: [
              const Icon(Icons.location_off, color: C.danger, size: 20),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(core.locationMsg!,
                      style: const TextStyle(fontSize: 13))),
              TextButton(
                  onPressed: () async {
                    await Geolocator.openAppSettings();
                    core.startLocation();
                  },
                  child: const Text('الإعدادات')),
              TextButton(
                  onPressed: core.startLocation, child: const Text('إعادة')),
            ]),
          ),
        Row(children: [
          chip(Icons.home_rounded, 'البيت', core.home?.name ?? 'اضغط للتعيين', true),
          const SizedBox(width: 10),
          chip(Icons.work_rounded, 'العمل', core.work?.name ?? 'اضغط للتعيين', false),
        ]),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: () => core.setTab(3),
          icon: const Icon(Icons.directions),
          label: const Text('إلى أين تريد الذهاب؟'),
        ),
      ]),
    );
  }
}

class PreviewPanel extends StatelessWidget {
  const PreviewPanel({super.key, required this.core});
  final SayyarCore core;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: cardDeco(),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Icon(Icons.location_on, color: C.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text(core.dest?.name ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ),
          IconButton(onPressed: core.cancelTrip, icon: const Icon(Icons.close)),
        ]),
        if (core.routeError != null) ...[
          const SizedBox(height: 4),
          Text(core.routeError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: C.muted)),
          const SizedBox(height: 12),
          FilledButton(
              onPressed: core.retryRoutes, child: const Text('إعادة المحاولة')),
        ] else ...[
          for (int i = 0; i < core.routes.length; i++)
            RouteTile(
              route: core.routes[i],
              selected: i == core.selected,
              onTap: () => core.selectRoute(i),
            ),
          const SizedBox(height: 4),
          FilledButton.icon(
            onPressed: core.startNavigation,
            icon: const Icon(Icons.navigation),
            label: const Text('ابدأ الملاحة'),
          ),
        ],
      ]),
    );
  }
}

class RouteTile extends StatelessWidget {
  const RouteTile(
      {super.key,
      required this.route,
      required this.selected,
      required this.onTap});
  final RouteOption route;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final eta = DateTime.now().add(Duration(seconds: route.duration.round()));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? C.panel2 : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: selected ? C.mint : C.mint.withValues(alpha: .15),
                width: selected ? 2 : 1),
          ),
          child: Row(children: [
            Icon(selected ? Icons.check_circle : Icons.circle_outlined,
                color: selected ? C.mint : C.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(route.label,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, color: C.mintSoft)),
                    Text(fmtDur(route.duration),
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w800)),
                  ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(fmtDist(route.distance),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('وصول ${fmtTime(eta)}',
                  style: const TextStyle(fontSize: 12, color: C.muted)),
            ]),
          ]),
        ),
      ),
    );
  }
}

class NavPanel extends StatelessWidget {
  const NavPanel({super.key, required this.core});
  final SayyarCore core;

  @override
  Widget build(BuildContext context) {
    final eta = DateTime.now().add(Duration(seconds: core.remSecs.round()));
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: cardDeco(),
      child: Row(children: [
        Container(
          width: 62,
          height: 62,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: C.ink,
            border: Border.all(color: C.mint, width: 2.5),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('${core.speedKmh.round()}',
                style: const TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w800, height: 1)),
            const Text('كم/س', style: TextStyle(fontSize: 9, color: C.muted)),
          ]),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(fmtDur(core.remSecs),
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w800, color: C.mint)),
                Text('${fmtDist(core.remDist)} • وصول ${fmtTime(eta)}',
                    style: const TextStyle(color: C.muted, fontSize: 13)),
              ]),
        ),
        roundBtn(core.voice ? Icons.volume_up : Icons.volume_off, core.toggleVoice),
        const SizedBox(width: 8),
        roundBtn(Icons.close, () => _confirmEnd(context), bg: C.danger, fg: Colors.white),
      ]),
    );
  }

  void _confirmEnd(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.panel,
        title: const Text('إنهاء الملاحة؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('استمرار')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              core.cancelTrip();
            },
            child: const Text('إنهاء', style: TextStyle(color: C.danger)),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  البحث عن الأماكن
// ════════════════════════════════════════════════════════════════════
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.core, this.pick = false});
  final SayyarCore core;
  final bool pick;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _ctl = TextEditingController();
  List<Place> _results = [];
  bool _loading = false;
  bool _searched = false;
  String? _error;

  static const _cats = [
    ('مستشفى', 'hospital', Icons.local_hospital),
    ('صيدلية', 'pharmacy', Icons.local_pharmacy),
    ('وقود', 'fuel', Icons.local_gas_station),
    ('مطعم', 'restaurant', Icons.restaurant),
    ('مول', 'mall', Icons.shopping_bag),
    ('فندق', 'hotel', Icons.hotel),
    ('مسجد', 'mosque', Icons.mosque),
    ('بنك', 'bank', Icons.account_balance),
  ];

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _run(String q, {bool near = false}) async {
    final query = q.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _searched = true;
    });
    try {
      final r =
          await Api.search(query, near: widget.core.me, nearOnly: near);
      if (!mounted) return;
      setState(() {
        _results = r;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _results = [];
        _error = 'تعذر البحث. تحقق من الاتصال بالإنترنت';
      });
    }
  }

  void _choose(Place p) {
    if (widget.pick) {
      Navigator.of(context).pop(p);
    } else {
      widget.core.goTo(p);
    }
  }

  @override
  Widget build(BuildContext context) {
    final core = widget.core;
    final body = ListenableBuilder(
      listenable: core,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          children: [
            if (!widget.pick) ...[
              const PageHeader(
                  icon: Icons.travel_explore,
                  title: 'البحث عن الأماكن',
                  sub: 'ابحث عن أي مكان داخل العراق'),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _ctl,
              textInputAction: TextInputAction.search,
              onSubmitted: _run,
              decoration: InputDecoration(
                hintText: 'مثلاً: مجمع بغداد التجاري',
                filled: true,
                fillColor: C.panel,
                prefixIcon: const Icon(Icons.search, color: C.mint),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_back, color: C.mint),
                  onPressed: () => _run(_ctl.text),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(color: C.mint.withValues(alpha: .3)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide(color: C.mint.withValues(alpha: .3)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: const BorderSide(color: C.mint, width: 1.6),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _cats.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final c = _cats[i];
                  return ActionChip(
                    avatar: Icon(c.$3, size: 18, color: C.mint),
                    label: Text(c.$1),
                    backgroundColor: C.panel2,
                    side: BorderSide(color: C.mint.withValues(alpha: .2)),
                    onPressed: () {
                      _ctl.text = c.$1;
                      _run(c.$2, near: true);
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 14),
            if (widget.pick && core.me != null)
              Tile(
                icon: Icons.my_location,
                title: 'موقعي الحالي',
                onTap: () => Navigator.of(context)
                    .pop(Place('موقعي الحالي', '', core.me!)),
              ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(30),
                child: Center(child: CircularProgressIndicator(color: C.mint)),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: C.muted)),
              )
            else if (_searched && _results.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('ما لقينا نتيجة، جرّب اسم أوضح',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: C.muted)),
              )
            else if (_results.isNotEmpty)
              ...[
                for (final p in _results)
                  Tile(
                    icon: Icons.place,
                    title: p.name,
                    sub: p.subtitle,
                    onTap: () => _choose(p),
                    trailing: widget.pick
                        ? null
                        : IconButton(
                            icon: Icon(
                                core.isSaved(p)
                                    ? Icons.star_rounded
                                    : Icons.star_border_rounded,
                                color: C.mint),
                            onPressed: () => core.toggleSaved(p),
                          ),
                  ),
              ]
            else if (core.recents.isNotEmpty) ...[
              Row(children: [
                const Expanded(
                  child: Text('الوجهات الأخيرة',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                TextButton(
                    onPressed: core.clearRecents, child: const Text('مسح')),
              ]),
              const SizedBox(height: 6),
              for (final p in core.recents)
                Tile(
                  icon: Icons.history,
                  title: p.name,
                  sub: p.subtitle,
                  onTap: () => _choose(p),
                ),
            ],
          ],
        );
      },
    );
    return widget.pick ? body : SafeArea(child: body);
  }
}

// ════════════════════════════════════════════════════════════════════
//  المفضلة
// ════════════════════════════════════════════════════════════════════
class FavoritesPage extends StatelessWidget {
  const FavoritesPage({super.key, required this.core});
  final SayyarCore core;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: core,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              const PageHeader(
                  icon: Icons.star_rounded,
                  title: 'المفضلة',
                  sub: 'أماكنك المهمة للوصول السريع'),
              const SizedBox(height: 18),
              _slot(context, 'البيت', Icons.home_rounded, core.home, true),
              _slot(context, 'العمل', Icons.work_rounded, core.work, false),
              const SizedBox(height: 8),
              Row(children: [
                const Expanded(
                  child: Text('أماكن محفوظة',
                      style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final p = await pickPlace(context, core);
                    if (p != null && !core.isSaved(p)) core.toggleSaved(p);
                  },
                  icon: const Icon(Icons.add_location_alt_outlined, size: 20),
                  label: const Text('إضافة مكان'),
                ),
              ]),
              const SizedBox(height: 6),
              if (core.saved.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('ما عندك أماكن محفوظة بعد.\nابحث عن مكان واضغط على النجمة لحفظه.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: C.muted)),
                ),
              for (final p in core.saved)
                Tile(
                  icon: Icons.place,
                  title: p.name,
                  sub: p.subtitle,
                  onTap: () => core.goTo(p),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: C.muted),
                    onPressed: () => core.toggleSaved(p),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _slot(BuildContext context, String label, IconData icon, Place? p,
      bool isHome) {
    if (p == null) {
      return Tile(
        icon: icon,
        title: 'إضافة $label',
        sub: 'اضغط لاختيار المكان',
        onTap: () => homeWorkAction(context, core, isHome),
        trailing: const Icon(Icons.add, color: C.mint),
      );
    }
    return Tile(
      icon: icon,
      title: label,
      sub: p.name,
      onTap: () => core.goTo(p),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          icon: const Icon(Icons.edit_outlined, color: C.muted, size: 20),
          onPressed: () async {
            final np = await pickPlace(context, core);
            if (np == null) return;
            if (isHome) {
              core.setHome(np);
            } else {
              core.setWork(np);
            }
          },
        ),
        IconButton(
          icon: const Icon(Icons.close, color: C.muted, size: 20),
          onPressed: isHome ? core.clearHome : core.clearWork,
        ),
      ]),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  البلاغات
// ════════════════════════════════════════════════════════════════════
class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key, required this.core});
  final SayyarCore core;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  String _type = 'accident';
  final TextEditingController _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final core = widget.core;
    return SafeArea(
      child: ListenableBuilder(
        listenable: core,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              const PageHeader(
                  icon: Icons.campaign,
                  title: 'إبلاغ جديد',
                  sub: 'سيتم تسجيل البلاغ عند موقعك الحالي'),
              const SizedBox(height: 16),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.05,
                children: [
                  for (final t in kReportTypes)
                    InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => setState(() => _type = t.id),
                      child: Container(
                        decoration: BoxDecoration(
                          color: C.panel,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                              color: _type == t.id
                                  ? C.mint
                                  : C.mint.withValues(alpha: .15),
                              width: _type == t.id ? 2 : 1),
                        ),
                        child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                    color: t.color,
                                    borderRadius: BorderRadius.circular(14)),
                                child: Icon(t.icon, color: C.ink, size: 26),
                              ),
                              const SizedBox(height: 6),
                              Text(t.label,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontSize: 12, fontWeight: FontWeight.w600)),
                            ]),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _note,
                maxLines: 2,
                decoration: InputDecoration(
                  hintText: 'ملاحظة (اختياري)',
                  filled: true,
                  fillColor: C.panel,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: C.mint.withValues(alpha: .25)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () {
                  core.addReport(_type, _note.text.trim());
                  _note.clear();
                  FocusScope.of(context).unfocus();
                },
                icon: const Icon(Icons.send_rounded),
                label: const Text('إرسال البلاغ'),
              ),
              const SizedBox(height: 8),
              const Text(
                'البلاغات محفوظة حالياً على جهازك وتظهر على خريطتك لمدة 8 ساعات.',
                textAlign: TextAlign.center,
                style: TextStyle(color: C.muted, fontSize: 11),
              ),
              const SizedBox(height: 22),
              if (core.reports.isNotEmpty)
                const Text('بلاغاتك النشطة',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 8),
              for (final rp in core.reports)
                Tile(
                  icon: reportTypeOf(rp.type).icon,
                  iconColor: reportTypeOf(rp.type).color,
                  title: reportTypeOf(rp.type).label,
                  sub: rp.note.isEmpty ? fmtAgo(rp.time) : '${fmtAgo(rp.time)} • ${rp.note}',
                  onTap: () => core.focusOn(rp.point),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: C.muted),
                    onPressed: () => core.removeReport(rp.id),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  حسابي
// ════════════════════════════════════════════════════════════════════
class AccountPage extends StatelessWidget {
  const AccountPage({super.key, required this.core});
  final SayyarCore core;

  Widget _stat(String v, String l) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: C.panel,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: C.mint.withValues(alpha: .15)),
          ),
          child: Column(children: [
            Text(v,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w800, color: C.mint)),
            Text(l, style: const TextStyle(fontSize: 11, color: C.muted)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: core,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
            children: [
              const Center(child: AppLogo(size: 96)),
              const SizedBox(height: 12),
              const Center(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('سيّار',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                  SizedBox(width: 6),
                  Icon(Icons.verified, color: C.blue, size: 20),
                ]),
              ),
              const Center(
                child: Text('مستخدم سيّار',
                    style: TextStyle(color: C.muted, fontSize: 13)),
              ),
              const SizedBox(height: 18),
              Row(children: [
                _stat('${core.trips}', 'رحلات'),
                const SizedBox(width: 10),
                _stat(core.totalKm.toStringAsFixed(1), 'كم'),
                const SizedBox(width: 10),
                _stat('${core.reports.length}', 'بلاغات'),
              ]),
              const SizedBox(height: 20),
              Tile(
                icon: Icons.settings_outlined,
                title: 'الإعدادات',
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => SettingsPage(core: core))),
              ),
              Tile(
                icon: Icons.shield_outlined,
                title: 'الخصوصية والأمان',
                onTap: () => _info(context, 'الخصوصية والأمان',
                    'سيّار لا يطلب تسجيل دخول ولا يجمع أي بيانات عنك.\n\nموقعك يُستخدم داخل هاتفك لعرض الخريطة والملاحة. عند طلب مسار يُرسل موقعك والوجهة إلى خادم المسارات المفتوح (OSRM)، وعند البحث يُرسل نص البحث إلى Nominatim. أماكنك المفضلة وبلاغاتك تُحفظ على جهازك فقط.'),
              ),
              Tile(
                icon: Icons.help_outline,
                title: 'المساعدة والدعم',
                onTap: () => _info(context, 'المساعدة والدعم',
                    '• اضغط مطولاً على أي نقطة في الخريطة لاختيارها كوجهة.\n• استخدم زر الطبقات لتغيير نمط الخريطة.\n• أثناء الملاحة اسحب الخريطة لتحريكها، ثم اضغط زر الموقع للعودة للمتابعة.\n• تأكد من تفعيل الـ GPS ومنح إذن الموقع للتطبيق.'),
              ),
              Tile(
                icon: Icons.info_outline,
                title: 'عن سيّار',
                onTap: () => _info(context, 'سيّار SAYYAR  •  1.0.0',
                    'طريقك.. بأمان وأسرع وقت\nسيّار.. العراق أولاً\n\nبيانات الخرائط: © مساهمو OpenStreetMap\nالخلفيات: CARTO و Esri\nالبحث: Nominatim\nالمسارات: OSRM'),
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: () => _confirmWipe(context),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('حذف بياناتي المحلية'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: C.mint,
                  minimumSize: const Size.fromHeight(50),
                  side: const BorderSide(color: C.mint),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
              ),
              const SizedBox(height: 16),
              const Center(
                child: Text('SAYYAR • IRAQ',
                    style: TextStyle(color: C.mint, letterSpacing: 4, fontSize: 12)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _info(BuildContext context, String title, String body) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.panel,
        title: Text(title),
        content: SingleChildScrollView(child: Text(body, style: const TextStyle(height: 1.6))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('حسناً')),
        ],
      ),
    );
  }

  void _confirmWipe(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.panel,
        title: const Text('حذف كل البيانات؟'),
        content: const Text('سيتم حذف المفضلة والبلاغات والإعدادات المحفوظة على هذا الجهاز.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              core.wipe();
            },
            child: const Text('حذف', style: TextStyle(color: C.danger)),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  الإعدادات
// ════════════════════════════════════════════════════════════════════
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.core});
  final SayyarCore core;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: ListenableBuilder(
        listenable: core,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('الخريطة',
                  style: TextStyle(color: C.mint, fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (int i = 0; i < kMapStyles.length; i++)
                  ChoiceChip(
                    avatar: Icon(kMapStyles[i].icon,
                        size: 18, color: core.styleIndex == i ? C.ink : C.mint),
                    label: Text(kMapStyles[i].name),
                    selected: core.styleIndex == i,
                    selectedColor: C.mint,
                    backgroundColor: C.panel2,
                    labelStyle: TextStyle(
                        color: core.styleIndex == i ? C.ink : C.text,
                        fontWeight: FontWeight.w700),
                    onSelected: (_) => core.setStyle(i),
                  ),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: core.showReports,
                onChanged: core.setShowReports,
                title: const Text('عرض البلاغات على الخريطة'),
              ),
              const Divider(color: C.panel2, height: 28),
              const Text('الملاحة والصوت',
                  style: TextStyle(color: C.mint, fontWeight: FontWeight.w800)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: core.voice,
                onChanged: core.setVoice,
                title: const Text('الإرشاد الصوتي'),
                subtitle: const Text('تعليمات منطوقة بالعربية أثناء الملاحة'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: core.keepAwake,
                onChanged: core.setKeepAwake,
                title: const Text('إبقاء الشاشة مضاءة أثناء الملاحة'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.record_voice_over, color: C.mint),
                title: const Text('اختبار الصوت'),
                onTap: () => core.speak(
                    'أهلاً بك في سيّار، طريقك بأمان وأسرع وقت',
                    force: true),
              ),
              const Divider(color: C.panel2, height: 28),
              const Text('الموقع',
                  style: TextStyle(color: C.mint, fontWeight: FontWeight.w800)),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.my_location, color: C.mint),
                title: const Text('تحديد موقعي الآن'),
                onTap: core.startLocation,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.settings_applications, color: C.mint),
                title: const Text('فتح إعدادات إذن الموقع'),
                onTap: Geolocator.openAppSettings,
              ),
            ],
          );
        },
      ),
    );
  }
}
