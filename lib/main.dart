// ============================================================================
// BBNET TRACK · APP DE RASTREO · main.dart  (ETAPA 2 · segundo plano)
// ----------------------------------------------------------------------------
// Ahora la app rastrea AUNQUE la pantalla esté apagada o uses otras apps.
// Para eso usa un "servicio en segundo plano" que muestra una notificación
// permanente mientras rastrea (Android lo exige).
// ============================================================================

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';

const supabaseUrl = 'https://ejvrvhdlweivrexcrivf.supabase.co';
const supabaseAnonKey = 'sb_publishable_45nRA6haYBUpJNEzbAYObQ_fyjxO5Cm';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  // Preparar el comunicador con el servicio en segundo plano
  FlutterForegroundTask.initCommunicationPort();
  runApp(const MiApp());
}

final supabase = Supabase.instance.client;

// ============================================================================
// EL "CEREBRO" DEL SEGUNDO PLANO
// ----------------------------------------------------------------------------
// Esta clase corre en segundo plano. Cada cierto tiempo lee el GPS y manda
// la posición a Supabase, aunque la app esté minimizada o la pantalla apagada.
// ============================================================================

@pragma('vm:entry-point')
void iniciarCallback() {
  FlutterForegroundTask.setTaskHandler(MiTareaRastreo());
}

class MiTareaRastreo extends TaskHandler {
  String? _deviceId;
  String? _vehicleId;
  String? _companyId;
  int _enviadas = 0;

  // --- Para el filtro de calidad del GPS ---
  double? _ultLat;        // última latitud buena enviada
  double? _ultLon;        // última longitud buena enviada
  DateTime? _ultHora;     // hora de la última posición buena
  int _lecturas = 0;      // cuántas lecturas llevamos (para ignorar el arranque)

  // Configuración del filtro:
  static const double _precisionMaxMetros = 50;   // descarta si el GPS tiene más error que esto
  static const double _velocidadMaxKmh = 150;     // descarta saltos imposibles (auto/camioneta)
  static const int _lecturasIgnorarInicio = 2;    // ignora las primeras 2 (arranque en frío)

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // Al arrancar el servicio, leemos los datos guardados (device, empresa)
    _deviceId = await FlutterForegroundTask.getData<String>(key: 'deviceId');
    _vehicleId = await FlutterForegroundTask.getData<String>(key: 'vehicleId');
    _companyId = await FlutterForegroundTask.getData<String>(key: 'companyId');
  }

  // Esto se ejecuta cada X segundos (lo configuramos al arrancar)
  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      _lecturas++;

      // ---- FILTROS DE CALIDAD ----

      // Filtro 1: ignorar las primeras lecturas (arranque en frío del GPS)
      if (_lecturas <= _lecturasIgnorarInicio) {
        FlutterForegroundTask.updateService(
          notificationTitle: 'BBNet Track · Buscando señal',
          notificationText: 'Enganchando el GPS...',
        );
        return;
      }

      // Filtro 2: descartar posiciones imprecisas (mucho error de GPS)
      if (pos.accuracy > _precisionMaxMetros) {
        return; // posición poco confiable, la descartamos
      }

      // Filtro 3: descartar saltos imposibles (velocidad irreal entre 2 puntos)
      if (_ultLat != null && _ultLon != null && _ultHora != null) {
        final metros = Geolocator.distanceBetween(_ultLat!, _ultLon!, pos.latitude, pos.longitude);
        final segundos = DateTime.now().difference(_ultHora!).inSeconds;
        if (segundos > 0) {
          final kmh = (metros / segundos) * 3.6;
          if (kmh > _velocidadMaxKmh) {
            return; // salto imposible, es un error de GPS, lo descartamos
          }
        }
      }

      // ---- La posición pasó los filtros: la enviamos ----
      await supabase.from('locations').insert({
        'company_id': _companyId,
        'device_id': _deviceId,
        'vehicle_id': _vehicleId,
        'latitud': pos.latitude,
        'longitud': pos.longitude,
        'velocidad': (pos.speed * 3.6).clamp(0, 300),
        'fecha_gps': DateTime.now().toUtc().toIso8601String(),
      });

      await supabase.from('tracker_devices').update({
        'online': true,
        'ultima_conexion': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _deviceId!);

      // Guardamos esta posición como la última buena (para el filtro de saltos)
      _ultLat = pos.latitude;
      _ultLon = pos.longitude;
      _ultHora = DateTime.now();
      _enviadas++;

      FlutterForegroundTask.updateService(
        notificationTitle: 'BBNet Track · Rastreando',
        notificationText: 'Posiciones enviadas: $_enviadas',
      );
    } catch (e) {
      FlutterForegroundTask.updateService(
        notificationTitle: 'BBNet Track · Reintentando',
        notificationText: 'Sin conexión, reintentando...',
      );
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    // Al detener, marcamos el dispositivo como offline
    if (_deviceId != null) {
      await supabase.from('tracker_devices').update({'online': false}).eq('id', _deviceId!);
    }
  }
}

// ============================================================================
// LA APP (interfaz)
// ============================================================================

class MiApp extends StatelessWidget {
  const MiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BBNet Track',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF0a0e14),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0066ff),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: supabase.auth.currentSession == null
          ? const PantallaLogin()
          : const PantallaRastreo(),
    );
  }
}

// ---------------------------------------------------------------------------
// LOGIN (igual que antes)
// ---------------------------------------------------------------------------
class PantallaLogin extends StatefulWidget {
  const PantallaLogin({super.key});
  @override
  State<PantallaLogin> createState() => _PantallaLoginState();
}

class _PantallaLoginState extends State<PantallaLogin> {
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _cargando = false;
  String? _error;

  Future<void> _entrar() async {
    setState(() { _cargando = true; _error = null; });
    try {
      await supabase.auth.signInWithPassword(
        email: _emailCtrl.text.trim(),
        password: _passCtrl.text,
      );
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const PantallaRastreo()),
        );
      }
    } catch (e) {
      setState(() => _error = 'No se pudo entrar. Revisá el mail y la contraseña.');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 64, height: 64,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFF0066ff), Color(0xFF4d9fff)]),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.location_on, color: Colors.white, size: 32),
              ),
              const Text('BBNet Track',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 6),
              const Text('Ingresá para empezar a registrar tu recorrido',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Color(0xFF8a93a6))),
              const SizedBox(height: 30),
              TextField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(color: Colors.white),
                decoration: _decoracion('Email'),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _passCtrl,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: _decoracion('Contraseña'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Color(0xFFff4d5e), fontSize: 13)),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _cargando ? null : _entrar,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0066ff),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: Text(_cargando ? 'Entrando...' : 'Entrar',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  InputDecoration _decoracion(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Color(0xFF8a93a6)),
      filled: true,
      fillColor: const Color(0xFF131822),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF252d3d)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF252d3d)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// PANTALLA DE RASTREO (ahora arranca el servicio en segundo plano)
// ---------------------------------------------------------------------------
class PantallaRastreo extends StatefulWidget {
  const PantallaRastreo({super.key});
  @override
  State<PantallaRastreo> createState() => _PantallaRastreoState();
}

class _PantallaRastreoState extends State<PantallaRastreo> {
  bool _rastreando = false;
  String _estado = 'Preparando...';
  String? _deviceId;
  String? _vehicleId;
  String? _companyId;

  @override
  void initState() {
    super.initState();
    _configurarServicio();
    _prepararDispositivo();
    _chequearSiYaEstaCorriendo();
  }

  void _configurarServicio() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'bbnet_track_canal',
        channelName: 'BBNet Track Rastreo',
        channelDescription: 'Notificación mientras se rastrea la ubicación',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(10000), // cada 10 segundos
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> _chequearSiYaEstaCorriendo() async {
    final corriendo = await FlutterForegroundTask.isRunningService;
    if (mounted) setState(() => _rastreando = corriendo);
  }

  Future<void> _prepararDispositivo() async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    final perfil = await supabase.from('users').select('company_id').eq('id', userId).maybeSingle();
    if (perfil == null) {
      setState(() => _estado = 'No se encontró tu perfil');
      return;
    }

    final disp = await supabase
        .from('tracker_devices')
        .select('id, vehicle_id')
        .eq('company_id', perfil['company_id'])
        .eq('tipo', 'celular')
        .limit(1)
        .maybeSingle();

    if (disp == null) {
      setState(() => _estado = 'No hay un dispositivo celular cargado en el sistema.');
      return;
    }

    setState(() {
      _companyId = perfil['company_id'] as String;
      _deviceId = disp['id'] as String;
      _vehicleId = disp['vehicle_id'] as String?;
      _estado = _rastreando ? 'Rastreando en segundo plano' : 'Listo para empezar';
    });
  }

  Future<void> _alternar() async {
    if (_rastreando) {
      await _detener();
    } else {
      await _empezar();
    }
  }

  Future<void> _empezar() async {
    if (_deviceId == null) {
      setState(() => _estado = 'Todavía no está listo el dispositivo. Esperá un momento.');
      return;
    }

    // -------------------------------------------------------------------
    // PERMISOS · en el orden correcto que Android exige
    // -------------------------------------------------------------------

    // PASO 1: Notificaciones primero (Android 13+). Sin esto el servicio no vive.
    if (await Permission.notification.isDenied) {
      setState(() => _estado = 'Pidiendo permiso de notificaciones...');
      await Permission.notification.request();
    }

    // PASO 2: Ubicación básica ("mientras uso la app")
    var permisoUbic = await Permission.locationWhenInUse.status;
    if (!permisoUbic.isGranted) {
      setState(() => _estado = 'Pidiendo permiso de ubicación...');
      permisoUbic = await Permission.locationWhenInUse.request();
    }
    if (!permisoUbic.isGranted) {
      setState(() => _estado = '⚠️ Necesito el permiso de ubicación para funcionar.');
      return;
    }

    // PASO 3: Ubicación EN SEGUNDO PLANO ("todo el tiempo") — la clave
    var permisoSiempre = await Permission.locationAlways.status;
    if (!permisoSiempre.isGranted) {
      setState(() => _estado = 'Pidiendo ubicación en segundo plano...');
      permisoSiempre = await Permission.locationAlways.request();
    }

    // Si Android no lo concede directo, hay que activarlo a mano en Ajustes.
    // Le abrimos la pantalla de ajustes de la app y le explicamos qué hacer.
    if (!permisoSiempre.isGranted) {
      setState(() => _estado =
          '⚠️ Para rastrear con la pantalla apagada:\n'
          'Abrí los ajustes (se abren solos) → Permisos → Ubicación → '
          'elegí "Permitir todo el tiempo". Después volvé y tocá Empezar de nuevo.');
      await Future.delayed(const Duration(seconds: 1));
      await openAppSettings(); // abre los ajustes de la app
      return; // que el usuario active y vuelva a tocar Empezar
    }

    // PASO 4: Ignorar el ahorro de batería (ayuda a que Android no la mate)
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      setState(() => _estado = 'Pidiendo permiso de batería...');
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }

    // -------------------------------------------------------------------
    // Todos los permisos OK: arrancamos el servicio
    // -------------------------------------------------------------------
    await FlutterForegroundTask.saveData(key: 'deviceId', value: _deviceId!);
    await FlutterForegroundTask.saveData(key: 'vehicleId', value: _vehicleId ?? '');
    await FlutterForegroundTask.saveData(key: 'companyId', value: _companyId!);

    await FlutterForegroundTask.startService(
      notificationTitle: 'BBNet Track · Rastreando',
      notificationText: 'Tu ubicación se está registrando',
      callback: iniciarCallback,
    );

    setState(() { _rastreando = true; _estado = '✅ Rastreando en segundo plano'; });
  }

  Future<void> _detener() async {
    await FlutterForegroundTask.stopService();
    setState(() { _rastreando = false; _estado = 'Detenido'; });
  }

  Future<void> _salir() async {
    await _detener();
    await supabase.auth.signOut();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const PantallaLogin()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF131822),
        title: const Text('BBNet Track', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(onPressed: _salir, icon: const Icon(Icons.logout), tooltip: 'Salir'),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 160, height: 160,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _rastreando ? const Color(0xFF22d97a).withOpacity(0.15) : const Color(0xFF131822),
                  border: Border.all(
                    color: _rastreando ? const Color(0xFF22d97a) : const Color(0xFF252d3d),
                    width: 3,
                  ),
                ),
                child: Icon(
                  _rastreando ? Icons.gps_fixed : Icons.gps_off,
                  size: 64,
                  color: _rastreando ? const Color(0xFF22d97a) : const Color(0xFF8a93a6),
                ),
              ),
            ),
            const SizedBox(height: 28),
            Text(_estado,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: Colors.white, fontWeight: FontWeight.w500)),
            const SizedBox(height: 8),
            if (_rastreando)
              const Text('Podés apagar la pantalla o usar otras apps.\nEl rastreo sigue funcionando.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Color(0xFF8a93a6))),
            const SizedBox(height: 36),
            FilledButton(
              onPressed: _alternar,
              style: FilledButton.styleFrom(
                backgroundColor: _rastreando ? const Color(0xFFff4d5e) : const Color(0xFF0066ff),
                padding: const EdgeInsets.symmetric(vertical: 18),
              ),
              child: Text(
                _rastreando ? 'Detener' : 'Empezar a rastrear',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
