// ignore_for_file: prefer_final_fields
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:sensors_plus/sensors_plus.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

// BLE UUIDs
final _serviceUUID    = UUID.fromString('0000FFE0-0000-1000-8000-00805F9B34FB');
final _biteCharUUID   = UUID.fromString('0000FFE1-0000-1000-8000-00805F9B34FB');
final _commandCharUUID = UUID.fromString('0000FFE2-0000-1000-8000-00805F9B34FB');

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

  bool _gattSetupDone = false;

  Future<void> _initBle() async {
    // 런타임 BLE 권한 요청 (Android 12+)
    await [
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();

    _bleStateSub = _peripheral.stateChanged.listen((args) {
      if (args.state == BluetoothLowEnergyState.poweredOn && !_gattSetupDone) {
        _setupGattServer();
      }
    });
    // 잠시 후 시도 (BLE 스택 초기화 대기)
    await Future.delayed(const Duration(milliseconds: 800));
    if (!_gattSetupDone) _setupGattServer();
  }

  Future<void> _setupGattServer() async {
    try {
      final biteChar = GATTCharacteristic.mutable(
        uuid: _biteCharUUID,
        properties: [GATTCharacteristicProperty.notify],
        permissions: [],
        descriptors: [], // CCCD는 라이브러리가 자동 관리 (직접 선언하면 수동 응답 필요)
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
      _writeReqSub = _peripheral.characteristicWriteRequested.listen((args) async {
        _handleCommand(utf8.decode(args.request.value));
        // write-with-response 요청에는 응답 필수 (안 하면 컨트롤러 타임아웃)
        try {
          await _peripheral.respondWriteRequest(args.request);
        } catch (_) {
          // write-without-response는 응답 불필요, 예외 무시
        }
      });

      await _peripheral.startAdvertising(Advertisement(
        name: 'KREFT Float',
        serviceUUIDs: [_serviceUUID],
      ));

      _gattSetupDone = true;
      setState(() {
        _bleStatus = '광고 중... 연결 대기';
        _bleReady = true;
      });
    } catch (e) {
      setState(() => _bleStatus = 'BLE 오류');
    }
  }

  void _handleCommand(String cmd) {
    // BLINK는 별도 처리 (Timer 사용)
    if (cmd == 'BLINK') {
      _startBlink();
      return;
    }
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

  // 위치 확인용 깜빡임 (컨트롤러에서 BLINK 명령 수신 시)
  void _startBlink() {
    final originalColor = _kemiColor;
    int count = 0;
    Timer.periodic(const Duration(milliseconds: 300), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (count >= 8) {
        timer.cancel();
        if (mounted) setState(() => _kemiColor = originalColor);
        return;
      }
      setState(() => _kemiColor = count.isEven ? Colors.white : originalColor);
      count++;
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
    setState(() => _autoDimFactor = 1.0);   // 대기 초기 100%
    _timer10s = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _autoDimFactor = 0.5);  // 10초 후 50%
    });
    _timer30s = Timer(const Duration(seconds: 30), () {
      if (mounted) setState(() => _autoDimFactor = 0.3);  // 30초 후 30%
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
      ).then((_) {
        setState(() => _bleStatus = '연결됨 — BITE 전송 성공');
      }).catchError((e) {
        setState(() => _bleStatus = '알림 오류: $e');
      });
    } else {
      setState(() => _bleStatus =
          'BITE 조건 미충족: ready=$_bleReady char=${_biteChar != null} central=${_connectedCentral != null}');
    }

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _isBite = false;
          _kemiColor = Colors.redAccent;
        });
        _resetBrightnessTimers(); // 입질 후 빨강 100%로 재시작
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
    // 밝기 곡선 보정: 50%→0.80, 30%→0.72 (급격한 어두움 방지)
    final glowAlpha = _isOn ? (finalAlpha * 0.4 + 0.6) : 0.0;
    final displayPercent = (finalAlpha * 100).toInt();

    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 화면 높이에서 상하 여백(160) 제외한 공간을 찌에 배분
            final floatHeight = (constraints.maxHeight - 160).clamp(300.0, 600.0);
            final scale = floatHeight / 520.0; // 520 = 기본 찌 전체 높이
            final kemiH = 35 * scale;
            final topH  = 160 * scale;
            final bodyH = 170 * scale;
            final legH  = 150 * scale;
            final bodyW = 26 * scale;

            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // BLE 상태
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _connectedCentral != null ? Icons.bluetooth_connected : Icons.bluetooth_searching,
                        color: _connectedCentral != null ? Colors.blueAccent : Colors.orange,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          _bleStatus,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _connectedCentral != null ? Colors.blueAccent : Colors.orange,
                            fontSize: 12,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '현재 케미 밝기: $displayPercent%',
                  style: TextStyle(
                    color: Colors.amber.withValues(alpha: finalAlpha.clamp(0.1, 1.0)),
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 16),

                // 찌 터치 영역 (가상 입질)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (!_isBite && _isOn) _onBite();
                  },
                  child: Stack(
                    alignment: Alignment.topCenter,
                    clipBehavior: Clip.none,
                    children: [
                      // 찌 이미지
                      ColorFiltered(
                        colorFilter: _isOn
                            ? const ColorFilter.mode(Colors.transparent, BlendMode.dst)
                            : ColorFilter.mode(Colors.grey.shade700.withValues(alpha: 0.6), BlendMode.srcATop),
                        child: Image.asset(
                          'assets/images/float_kreft.png',
                          height: floatHeight,
                          fit: BoxFit.fitHeight,
                        ),
                      ),
                      // LED 글로우 오버레이 — 찌탑 흰색 케미 위치
                      // 크기는 최소 75% 유지(급격한 축소 방지), 밝기(alpha)만 단계적으로 감소
                      AnimatedPositioned(
                        duration: const Duration(milliseconds: 400),
                        top: -(50.0 * finalAlpha.clamp(0.75, 1.0) / 2.0),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 400),
                          width: 50.0 * finalAlpha.clamp(0.75, 1.0),
                          height: 50.0 * finalAlpha.clamp(0.75, 1.0),
                          decoration: _isOn
                              ? BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: RadialGradient(
                                    colors: [
                                      Colors.white.withValues(alpha: 0.95 * glowAlpha),
                                      _kemiColor.withValues(alpha: 0.9 * glowAlpha),
                                      _kemiColor.withValues(alpha: 0.4 * glowAlpha),
                                      _kemiColor.withValues(alpha: 0.0),
                                    ],
                                    stops: const [0.0, 0.25, 0.6, 1.0],
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
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
            );
          },
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
