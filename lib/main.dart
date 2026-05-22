// ============================================================================
// BBNET TRACK · APP DE RASTREO · main.dart  (ETAPA 2 · segundo plano)
// ----------------------------------------------------------------------------
// Ahora la app rastrea AUNQUE la pantalla esté apagada o uses otras apps.
// Para eso usa un "servicio en segundo plano" que muestra una notificación
// permanente mientras rastrea (Android lo exige).
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:battery_plus/battery_plus.dart';

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

    // CLAVE: el cerebro del segundo plano corre en un espacio AISLADO,
    // donde Supabase NO está inicializado. Lo inicializamos acá, y
    // recuperamos la sesión con el token guardado, para poder enviar datos.
    try {
      await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
    } catch (_) {
      // Si ya estaba inicializado, ignoramos el error
    }
    final refreshToken = await FlutterForegroundTask.getData<String>(key: 'refreshToken');
    if (refreshToken != null && refreshToken.isNotEmpty) {
      try {
        await Supabase.instance.client.auth.setSession(refreshToken);
      } catch (_) {}
    }
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

      // ---- La posición pasó los filtros ----
      // Leemos el nivel de batería del celular (0-100)
      int? nivelBateria;
      try {
        nivelBateria = await Battery().batteryLevel;
      } catch (_) {
        nivelBateria = null; // si no se puede leer, lo dejamos vacío
      }

      // Armamos el registro de esta posición
      final registro = {
        'company_id': _companyId,
        'device_id': _deviceId,
        'vehicle_id': _vehicleId,
        'latitud': pos.latitude,
        'longitud': pos.longitude,
        'velocidad': (pos.speed * 3.6).clamp(0, 300),
        'bateria': nivelBateria,
        'fecha_gps': DateTime.now().toUtc().toIso8601String(),
      };

      // Guardamos esta posición como la última buena (para el filtro de saltos)
      _ultLat = pos.latitude;
      _ultLon = pos.longitude;
      _ultHora = DateTime.now();

      final sb = Supabase.instance.client;

      try {
        // Intentamos mandar PRIMERO lo que haya pendiente (cola offline)
        await _enviarPendientes(sb);

        // Después mandamos la posición actual
        await sb.from('locations').insert(registro);
        await sb.from('tracker_devices').update({
          'online': true,
          'ultima_conexion': DateTime.now().toUtc().toIso8601String(),
          'bateria': nivelBateria,
        }).eq('id', _deviceId!);

        _enviadas++;
        FlutterForegroundTask.updateService(
          notificationTitle: 'BBNet Track · Rastreando',
          notificationText: 'Posiciones enviadas: $_enviadas',
        );
      } catch (e) {
        // No hay conexión: guardamos la posición en la cola offline
        await _guardarEnCola(registro);
        final pendientes = await _contarPendientes();
        FlutterForegroundTask.updateService(
          notificationTitle: 'BBNet Track · Sin señal',
          notificationText: 'Guardando offline ($pendientes pendientes)',
        );
      }
    } catch (e) {
      // Error al leer el GPS u otro: lo mostramos
      final msg = e.toString();
      FlutterForegroundTask.updateService(
        notificationTitle: 'BBNet Track · Error',
        notificationText: msg.length > 80 ? msg.substring(0, 80) : msg,
      );
    }
  }

  // -------------------------------------------------------------------
  // COLA OFFLINE · guarda posiciones cuando no hay internet
  // -------------------------------------------------------------------

  // Guarda un registro en la cola (lista de espera) local
  Future<void> _guardarEnCola(Map<String, dynamic> registro) async {
    final actual = await FlutterForegroundTask.getData<String>(key: 'colaOffline') ?? '[]';
    final List lista = jsonDecode(actual);
    lista.add(registro);
    // Límite de seguridad: máximo 5000 posiciones guardadas (no llenar el celular)
    if (lista.length > 5000) lista.removeAt(0);
    await FlutterForegroundTask.saveData(key: 'colaOffline', value: jsonEncode(lista));
  }

  // Cuenta cuántas posiciones hay esperando
  Future<int> _contarPendientes() async {
    final actual = await FlutterForegroundTask.getData<String>(key: 'colaOffline') ?? '[]';
    final List lista = jsonDecode(actual);
    return lista.length;
  }

  // Intenta enviar todas las posiciones pendientes (cuando vuelve internet)
  Future<void> _enviarPendientes(SupabaseClient sb) async {
    final actual = await FlutterForegroundTask.getData<String>(key: 'colaOffline') ?? '[]';
    final List lista = jsonDecode(actual);
    if (lista.isEmpty) return;

    // Mandamos todas juntas (en orden). Si falla, queda para el próximo intento.
    await sb.from('locations').insert(List<Map<String, dynamic>>.from(lista));

    // Si llegó acá, se enviaron bien: limpiamos la cola
    await FlutterForegroundTask.saveData(key: 'colaOffline', value: '[]');
    _enviadas += lista.length;
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    // Al detener, marcamos el dispositivo como offline
    if (_deviceId != null) {
      try {
        await Supabase.instance.client.from('tracker_devices').update({'online': false}).eq('id', _deviceId!);
      } catch (_) {}
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
  String _nombreDispositivo = '';

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
    _companyId = perfil['company_id'] as String;

    // ¿Ya eligió un vehículo antes? (lo recordamos en el celular)
    final guardadoDeviceId = await FlutterForegroundTask.getData<String>(key: 'miDeviceId');

    if (guardadoDeviceId != null && guardadoDeviceId.isNotEmpty) {
      // Ya tiene vehículo elegido: lo cargamos
      final disp = await supabase
          .from('tracker_devices')
          .select('id, vehicle_id, nombre')
          .eq('id', guardadoDeviceId)
          .maybeSingle();
      if (disp != null) {
        setState(() {
          _deviceId = disp['id'] as String;
          _vehicleId = disp['vehicle_id'] as String?;
          _nombreDispositivo = disp['nombre'] as String? ?? 'Mi vehículo';
          _estado = _rastreando ? 'Rastreando en segundo plano' : 'Listo para empezar';
        });
        return;
      }
    }

    // No eligió todavía: mostramos la pantalla de selección
    if (mounted) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PantallaElegirVehiculo(companyId: _companyId!),
      )).then((_) => _prepararDispositivo()); // al volver, recargamos
    }
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
    // Guardamos el refresh token para que el cerebro del segundo plano
    // pueda autenticarse con Supabase en su espacio aislado.
    final sesion = supabase.auth.currentSession;
    if (sesion != null && sesion.refreshToken != null) {
      await FlutterForegroundTask.saveData(key: 'refreshToken', value: sesion.refreshToken!);
    }

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

  // Cambiar de vehículo: borra la elección guardada y vuelve a preguntar
  Future<void> _cambiarVehiculo() async {
    if (_rastreando) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Detené el rastreo antes de cambiar de vehículo')),
      );
      return;
    }
    await FlutterForegroundTask.removeData(key: 'miDeviceId');
    setState(() { _deviceId = null; _vehicleId = null; _nombreDispositivo = ''; });
    if (mounted) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PantallaElegirVehiculo(companyId: _companyId!),
      )).then((_) => _prepararDispositivo());
    }
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
          IconButton(onPressed: _cambiarVehiculo, icon: const Icon(Icons.directions_car), tooltip: 'Cambiar vehículo'),
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
            if (_nombreDispositivo.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF131822),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFF252d3d)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.directions_car, color: Color(0xFF4d9fff), size: 16),
                    const SizedBox(width: 6),
                    Text(_nombreDispositivo,
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
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

// ============================================================================
// PANTALLA: ELEGIR VEHÍCULO
// ----------------------------------------------------------------------------
// Muestra los dispositivos (celular) de la empresa para que el chofer elija
// cuál es el suyo. La elección se guarda y no se vuelve a preguntar.
// ============================================================================
class PantallaElegirVehiculo extends StatefulWidget {
  final String companyId;
  const PantallaElegirVehiculo({super.key, required this.companyId});

  @override
  State<PantallaElegirVehiculo> createState() => _PantallaElegirVehiculoState();
}

class _PantallaElegirVehiculoState extends State<PantallaElegirVehiculo> {
  List<Map<String, dynamic>> _dispositivos = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // Traemos los dispositivos celular de la empresa, con el nombre del vehículo
    final data = await supabase
        .from('tracker_devices')
        .select('id, nombre, vehicle_id, vehicles(nombre)')
        .eq('company_id', widget.companyId)
        .eq('tipo', 'celular');
    setState(() {
      _dispositivos = List<Map<String, dynamic>>.from(data);
      _cargando = false;
    });
  }

  Future<void> _elegir(Map<String, dynamic> disp) async {
    // Guardamos la elección en el celular (queda fija)
    await FlutterForegroundTask.saveData(key: 'miDeviceId', value: disp['id'] as String);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF131822),
        title: const Text('Elegí tu vehículo', style: TextStyle(fontWeight: FontWeight.bold)),
        automaticallyImplyLeading: false,
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF0066ff)))
          : _dispositivos.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(28),
                    child: Text(
                      'No hay vehículos cargados todavía.\nPedile al administrador que cargue los dispositivos.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF8a93a6), fontSize: 15),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(bottom: 16, left: 4),
                      child: Text('Tocá el vehículo que estás usando:',
                        style: TextStyle(color: Color(0xFF8a93a6), fontSize: 14)),
                    ),
                    ..._dispositivos.map((disp) {
                      final vehiculo = disp['vehicles'];
                      final nombreVeh = vehiculo != null ? (vehiculo['nombre'] ?? '') : '';
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF131822),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF252d3d)),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                          leading: const Icon(Icons.directions_car, color: Color(0xFF4d9fff), size: 30),
                          title: Text(disp['nombre'] as String? ?? 'Dispositivo',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
                          subtitle: nombreVeh.isNotEmpty
                              ? Text('Vehículo: $nombreVeh', style: const TextStyle(color: Color(0xFF8a93a6)))
                              : null,
                          trailing: const Icon(Icons.chevron_right, color: Color(0xFF8a93a6)),
                          onTap: () => _elegir(disp),
                        ),
                      );
                    }),
                  ],
                ),
    );
  }
}
