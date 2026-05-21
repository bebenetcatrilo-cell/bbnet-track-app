// ============================================================================
// BBNET TRACK · APP DE RASTREO · main.dart  (ETAPA 1)
// ----------------------------------------------------------------------------
// Lo que hace esta app:
//   1) Pantalla de login (el técnico entra con su mail y contraseña)
//   2) Pide permiso de ubicación al celular
//   3) Lee la posición GPS real cada pocos segundos
//   4) La manda a Supabase (la misma base que usa el panel)
//
// Cuando esto anda, en el panel (Mapa en vivo) se ve el celular moverse.
// ============================================================================

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';

// ----------------------------------------------------------------------------
// DATOS DE TU SUPABASE (los mismos del panel)
// ----------------------------------------------------------------------------
const supabaseUrl = 'https://ejvrvhdlweivrexcrivf.supabase.co';
const supabaseAnonKey = 'sb_publishable_45nRA6haYBUpJNEzbAYObQ_fyjxO5Cm';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  runApp(const MiApp());
}

final supabase = Supabase.instance.client;

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
      // Si ya hay sesión abierta, va directo al panel; sino, al login
      home: supabase.auth.currentSession == null
          ? const PantallaLogin()
          : const PantallaRastreo(),
    );
  }
}

// ============================================================================
// PANTALLA DE LOGIN
// ============================================================================
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
              // Logo
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

// ============================================================================
// PANTALLA DE RASTREO (después del login)
// ============================================================================
class PantallaRastreo extends StatefulWidget {
  const PantallaRastreo({super.key});

  @override
  State<PantallaRastreo> createState() => _PantallaRastreoState();
}

class _PantallaRastreoState extends State<PantallaRastreo> {
  bool _rastreando = false;
  String _estado = 'Listo para empezar';
  int _enviadas = 0;
  Position? _ultima;
  StreamSubscription<Position>? _suscripcion;
  String? _deviceId;
  String? _vehicleId;

  @override
  void initState() {
    super.initState();
    _prepararDispositivo();
  }

  // Busca el dispositivo y vehículo de este usuario para saber a quién asociar
  Future<void> _prepararDispositivo() async {
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    // Buscamos el perfil del usuario (su empresa)
    final perfil = await supabase
        .from('users')
        .select('company_id')
        .eq('id', userId)
        .maybeSingle();

    if (perfil == null) {
      setState(() => _estado = 'No se encontró tu perfil');
      return;
    }

    // Buscamos un dispositivo de tipo celular de esta empresa.
    // (En la Etapa 1, usamos el primero que haya. Después se puede elegir.)
    final disp = await supabase
        .from('tracker_devices')
        .select('id, vehicle_id')
        .eq('company_id', perfil['company_id'])
        .eq('tipo', 'celular')
        .limit(1)
        .maybeSingle();

    if (disp == null) {
      setState(() => _estado = 'No hay un dispositivo celular cargado en el sistema.\nPedile al administrador que cree uno.');
      return;
    }

    setState(() {
      _deviceId = disp['id'] as String;
      _vehicleId = disp['vehicle_id'] as String?;
      _estado = 'Listo para empezar';
    });
  }

  Future<void> _alternarRastreo() async {
    if (_rastreando) {
      _detener();
    } else {
      await _empezar();
    }
  }

  Future<void> _empezar() async {
    if (_deviceId == null) {
      setState(() => _estado = 'Todavía no está listo el dispositivo. Esperá un momento.');
      return;
    }

    // 1) Pedir permiso de ubicación
    LocationPermission permiso = await Geolocator.checkPermission();
    if (permiso == LocationPermission.denied) {
      permiso = await Geolocator.requestPermission();
    }
    if (permiso == LocationPermission.denied || permiso == LocationPermission.deniedForever) {
      setState(() => _estado = 'Necesito permiso de ubicación para funcionar.');
      return;
    }

    // 2) Chequear que el GPS esté prendido
    final servicioActivo = await Geolocator.isLocationServiceEnabled();
    if (!servicioActivo) {
      setState(() => _estado = 'Prendé la ubicación (GPS) del celular.');
      return;
    }

    // 3) Empezar a escuchar la posición y mandarla
    setState(() { _rastreando = true; _estado = 'Rastreando...'; });

    _suscripcion = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10, // manda cada 10 metros de movimiento
      ),
    ).listen((pos) => _enviarPosicion(pos));
  }

  void _detener() {
    _suscripcion?.cancel();
    _suscripcion = null;
    setState(() { _rastreando = false; _estado = 'Detenido'; });
  }

  // Manda una posición a Supabase
  Future<void> _enviarPosicion(Position pos) async {
    try {
      final userId = supabase.auth.currentUser?.id;
      final perfil = await supabase.from('users').select('company_id').eq('id', userId!).single();

      await supabase.from('locations').insert({
        'company_id': perfil['company_id'],
        'device_id': _deviceId,
        'vehicle_id': _vehicleId,
        'latitud': pos.latitude,
        'longitud': pos.longitude,
        'velocidad': (pos.speed * 3.6).clamp(0, 300), // m/s a km/h
        'fecha_gps': DateTime.now().toUtc().toIso8601String(),
      });

      // Actualizamos el dispositivo (online + última conexión)
      await supabase.from('tracker_devices').update({
        'online': true,
        'ultima_conexion': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', _deviceId!);

      setState(() {
        _ultima = pos;
        _enviadas++;
        _estado = 'Rastreando...';
      });
    } catch (e) {
      setState(() => _estado = 'Error al enviar: revisá la conexión');
    }
  }

  Future<void> _salir() async {
    _detener();
    await supabase.auth.signOut();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const PantallaLogin()),
      );
    }
  }

  @override
  void dispose() {
    _suscripcion?.cancel();
    super.dispose();
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
            // Círculo de estado
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

            if (_rastreando) ...[
              Text('Posiciones enviadas: $_enviadas',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Color(0xFF8a93a6))),
              if (_ultima != null)
                Text('Última: ${_ultima!.latitude.toStringAsFixed(5)}, ${_ultima!.longitude.toStringAsFixed(5)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF5a6478))),
            ],

            const SizedBox(height: 36),

            FilledButton(
              onPressed: _alternarRastreo,
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
