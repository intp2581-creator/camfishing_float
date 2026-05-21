// ignore_for_file: prefer_final_fields
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

// BLE UUIDs
final _serviceUUID    = UUID.fromString('0000FFE0-0000-1000-8000-00805F9B34FB');
final _biteCharUUID   = UUID.fromString('0000FFE1-0000-1000-8000-00805F9B34FB');
final _commandCharUUID = UUID.fromString('0000FFE2-0000-1000-8000-00805F9B34FB');
final _cccdUUID       = UUID.fromString('00002902-0000-1000-8000-00805F9B34FB');

void main() {
  runApp(const VirtualFloatApp());
}

class VirtualFloatApp extends StatelessWidget {
  const VirtualFloatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark),
      home: const VirtualFloatHomeScreen(),
    );
  }
}

class VirtualFloatHomeScreen extends StatefulWidget {
  const VirtualFloatHomeScreen({super.key});

  @override
  State<VirtualFloatHomeScreen> createState() => _VirtualFloatHomeScreenState();
}

class _VirtualFloatHomeScreenState extends State<VirtualFloatHomeScreen> {
  // 찌 상태
  Color _kemiColor = Colors.redAccent;
  double _biteThreshold = 3.5;
  double _baseBrightness = 1.0;
  double _autoDimFactor = 1.0;
  bool _isBite = false;
  bool _isOn = true;

  // BLE
  final _peripheral = PeripheralManager();
  GATTCharacteristic? _biteChar;
  Central? _connectedCentral;
  String _bleStatus = 'BLE 초기화 중...';
  bool _bleReady = false;

  // 타이머 & 센서
  Timer? _timer10s;
  Timer? _timer30s;
  StreamSubscription<UserAccelerometerEvent>? _accelSub;
  StreamSubscription? _writeReqSub;
  StreamSubscription? _bleStateSub;
  StreamSubscription? _connStateSub;

  @override
  void initState() {
    super.initState();
    _initBle();
    _startSensor();
    _resetBrightnessTimers();
  }

  Future<void> _initBle() async {
    _bleStateSub = _peripheral.stateChanged.listen((args) {
      if (args.state == BluetoothLowEnergyState.poweredOn) {
        _setupGattServer();
      }
    });
    final state = await _peripheral.getState();
    if (state == BluetoothLowEnergyState.poweredOn) {
      _setupGattServer();
    }
  }

  Future<void> _setupGattServer() async {
    try {
      final biteChar = GATTCharacteristic.mutable(
        uuid: _biteCharUUID,
        properties: [GATTCharacteristicProperty.notify],
        permissions: [],
        descriptors: [
          GATTDescriptor.mutable(
            uuid: _cccdUUID,
            permissions: [
              GATTDescriptorPermission.read,
              GATTDescriptorPermission.write,
            ],
          ),
        ],
      );

      final commandChar = GATTCharacteristic.mutable(
        uuid: _commandCharUUID,
        properties: [
          GATTCharacteristicProperty.write,
          GATTCharacteristicProperty.writeWithoutResponse,
        ],
        permissions: [GATTCharacteristicPermission.write],
        descriptors: [],
      );

      final service = GATTService(
        uuid: _serviceUUID,
        isPrimary: true,
        includedServices: [],
        characteristics: [biteChar, commandChar],
      );

      await _peripheral.addService(service);
      _biteChar = biteChar;

      // 연결 상태 감지
      _connStateSub = _peripheral.connectionStateChanged.listen((args) {
        if (args.state == ConnectionState.connected) {
          setState(() {
            _connectedCentral = args.central;
            _bleStatus = '연결됨: ${args.central.uuid.toString().substring(0, 8)}...';
          });
        } else {
          setState(() {
            _connectedCentral = null;
            _bleStatus = '광고 중... 연결 대기';
          });
        }
      });

      // 컨트롤 앱에서 명령 수신
      _writeReqSub = _peripheral.characteristicWriteRequested.listen((args) {
        _handleCommand(utf8.decode(args.value));
      });

      await _peripheral.startAdvertising(Advertisement(
        name: 'KREFT Float',
        serviceUUIDs: [_serviceUUID],
      ));

      setState(() {
        _bleStatus = '광고 중... 연결 대기';
        _bleReady = true;
      });
    } catch (e) {
      setState(() => _bleStatus = 'BLE 오류: $e');
    }
  }

  void _handleCommand(String cmd) {
    setState(() {
      if (cmd == 'ON') {
        _isOn = true;
      } else if (cmd == 'OFF') {
        _isOn = false;
      } else if (cmd.startsWith('COLOR:')) {
        final parts = cmd.substring(6).split(',');
        if (parts.length == 3) {
          _kemiColor = Color.fromARGB(
            255,
            int.tryParse(parts[0]) ?? 255,
            int.tryParse(parts[1]) ?? 0,
            int.tryParse(parts[2]) ?? 0,
          );
        }
      } else if (cmd.startsWith('BRIGHTNESS:')) {
        _baseBrightness = double.tryParse(cmd.substring(11)) ?? 1.0;
      } else if (cmd.startsWith('SENSITIVITY:')) {
        _biteThreshold = double.tryParse(cmd.substring(12)) ?? 3.5;
      }
    });
  }

  void _startSensor() {
    _accelSub = userAccelerometerEventStream().listen((event) {
      if ((event.y > _biteThreshold || event.y < -_biteThreshold) && !_isBite && _isOn) {
        _onBite();
      }
    });
  }

  void _resetBrightnessTimers() {
    _timer10s?.cancel();
    _timer30s?.cancel();
    setState(() => _autoDimFactor = 1.0);
    _timer10s = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _autoDimFactor = 0.5);
    });
    _timer30s = Timer(const Duration(seconds: 30), () {
      if (mounted) setState(() => _autoDimFactor = 0.3);
    });
  }

  void _onBite() {
    setState(() {
      _isBite = true;
      _kemiColor = Colors.greenAccent;
    });
    _resetBrightnessTimers();

    // BLE로 입질 신호 송신
    if (_bleReady && _biteChar != null && _connectedCentral != null) {
      _peripheral.notifyCharacteristic(
        _connectedCentral!,
        _biteChar!,
        value: Uint8List.fromList(utf8.encode('BITE')),
      );
    }

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _isBite = false;
          _kemiColor = Colors.redAccent;
        });
      }
    });
  }

  @override
  void dispose() {
    _accelSub?.cancel();
    _writeReqSub?.cancel();
    _bleStateSub?.cancel();
    _connStateSub?.cancel();
    _timer10s?.cancel();
    _timer30s?.cancel();
    _peripheral.stopAdvertising();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final finalAlpha = _isOn ? (_baseBrightness * _autoDimFactor).clamp(0.0, 1.0) : 0.0;
    final displayPercent = (finalAlpha * 100).toInt();

    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // BLE 상태
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _connectedCentral != null ? Icons.bluetooth_connected : Icons.bluetooth_searching,
                  color: _connectedCentral != null ? Colors.blueAccent : Colors.orange,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Text(
                  _bleStatus,
                  style: TextStyle(
                    color: _connectedCentral != null ? Colors.blueAccent : Colors.orange,
                    fontSize: 12,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '현재 케미 밝기: $displayPercent%',
              style: TextStyle(
                color: Colors.amber.withValues(alpha: finalAlpha.clamp(0.1, 1.0)),
                letterSpacing: 2,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 50),

            // 찌 터치 영역 (가상 입질)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (!_isBite && _isOn) _onBite();
              },
              child: Stack(
                alignment: Alignment.topCenter,
                children: [
                  // 케미 (LED 발광부)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 500),
                    width: 6,
                    height: 35,
                    decoration: BoxDecoration(
                      color: _isOn
                          ? _kemiColor.withValues(alpha: finalAlpha)
                          : Colors.grey.shade900,
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: _isOn
                          ? [
                              BoxShadow(
                                color: _kemiColor.withValues(
                                    alpha: _isBite ? finalAlpha : finalAlpha * 0.4),
                                blurRadius: _isBite ? 30 : 10 * finalAlpha,
                                spreadRadius: _isBite ? 12 : 1 * finalAlpha,
                              )
                            ]
                          : null,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 35),
                    child: Column(
                      children: [
                        Container(width: 2, height: 5, color: Colors.grey[900]),
                        // 찌탑 (흑/적 패턴)
                        Container(
                          width: 4,
                          height: 160,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black, Colors.redAccent,
                                Colors.black, Colors.redAccent,
                                Colors.black, Colors.redAccent,
                                Colors.black, Colors.redAccent,
                              ],
                            ),
                          ),
                        ),
                        // 몸통
                        CustomPaint(
                          size: const Size(26, 170),
                          painter: FloatBodyPainter(),
                        ),
                        // 카본 다리
                        Container(width: 1.5, height: 150, color: Colors.grey[700]),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 50),
            Text(
              _isBite ? '입질 감지!' : (_isOn ? '대기 중...' : 'OFF'),
              style: TextStyle(
                color: _isBite
                    ? Colors.redAccent
                    : (_isOn ? Colors.white24 : Colors.grey),
                fontSize: 18,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FloatBodyPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height, cx = w / 2;

    final paint = Paint()
      ..shader = const RadialGradient(
        center: Alignment(-0.2, -0.4),
        radius: 1.2,
        colors: [Color(0xFF555555), Color(0xFF161616), Color(0xFF0A0A0A)],
        stops: [0.0, 0.6, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, w, h))
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(cx, 0)
      ..cubicTo(0, 0, 0, h * 0.2, 0, h * 0.2)
      ..quadraticBezierTo(0, h * 0.5, cx - 0.75, h)
      ..lineTo(cx + 0.75, h)
      ..quadraticBezierTo(w, h * 0.5, w, h * 0.2)
      ..cubicTo(w, h * 0.2, w, 0, cx, 0)
      ..close();

    canvas.drawPath(path, paint);

    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.amber.withValues(alpha: 0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );

    final tp = TextPainter(
      text: const TextSpan(
        text: 'K\nR\nE\nF\nT',
        style: TextStyle(
            color: Colors.amber, fontSize: 6.5, fontWeight: FontWeight.bold, height: 1.4),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, h * 0.2));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
