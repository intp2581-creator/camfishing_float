// ignore_for_file: prefer_final_fields, unused_field
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
  Color _baseKemiColor = Colors.redAccent; // 컨트롤 앱이 설정한 기본 색상 (입질 후 복원용)
  double _biteThreshold = 3.5;
  double _baseBrightness = 1.0;
  double _autoDimFactor = 1.0;
  bool _isBite = false;
  bool _isOn = true;

  // 10개 가상 찌 테스트
  final List<bool> _virtualBiteStates = List.generate(10, (_) => false);

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
        // connectionStateChanged가 누락될 수 있어서 명령 수신 시 Central도 캡처
        if (_connectedCentral == null && mounted) {
          setState(() {
            _connectedCentral = args.central;
            _bleStatus = '연결됨: ${args.central.uuid.toString().substring(0, 8)}...';
          });
        }
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
          final newColor = Color.fromARGB(
            255,
            int.tryParse(parts[0]) ?? 255,
            int.tryParse(parts[1]) ?? 0,
            int.tryParse(parts[2]) ?? 0,
          );
          _kemiColor = newColor;
          _baseKemiColor = newColor;
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
          _kemiColor = _baseKemiColor; // 컨트롤 앱에서 설정한 색상으로 복원
        });
        _resetBrightnessTimers(); // 입질 후 100%로 재시작
      }
    });
  }

  // 가상 찌 N번 입질 (BITE:N BLE 전송)
  void _onVirtualBite(int index) {
    final number = index + 1;
    if (_virtualBiteStates[index]) return; // 이미 입질 중
    setState(() => _virtualBiteStates[index] = true);

    if (_bleReady && _biteChar != null && _connectedCentral != null) {
      _peripheral.notifyCharacteristic(
        _connectedCentral!,
        _biteChar!,
        value: Uint8List.fromList(utf8.encode('BITE:$number')),
      ).then((_) {
        if (mounted) setState(() => _bleStatus = '연결됨 — BITE:$number 전송 성공');
      }).catchError((e) {
        if (mounted) setState(() => _bleStatus = '알림 오류: $e');
      });
    } else {
      setState(() => _bleStatus =
          'BITE 조건 미충족: ready=$_bleReady char=${_biteChar != null} central=${_connectedCentral != null}');
    }

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _virtualBiteStates[index] = false);
    });
  }

  Widget _buildVirtualFloat(int index, {
    double imgHeight = 100,
    double glowSize = 22,
    double badgeSize = 20,
    double fontSize = 9,
  }) {
    final number = index + 1;
    final isBiting = _virtualBiteStates[index];
    final ledColor = isBiting ? Colors.greenAccent : Colors.redAccent;
    final currentGlow = isBiting ? glowSize * 1.5 : glowSize;

    return GestureDetector(
      onTap: () => _onVirtualBite(index),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 찌 이미지 + LED 글로우 — Stack은 이미지 크기 기준
          Stack(
            alignment: Alignment.topCenter,
            clipBehavior: Clip.none,
            children: [
              // 찌 이미지
              Image.asset(
                'assets/images/float_kreft.png',
                height: imgHeight,
                fit: BoxFit.fitHeight,
              ),
              // LED 글로우 — 이미지 상단(찌탑)에 딱 맞춤
              Positioned(
                top: -(currentGlow / 2),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: currentGlow,
                  height: currentGlow,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        Colors.white.withValues(alpha: isBiting ? 1.0 : 0.9),
                        ledColor.withValues(alpha: isBiting ? 0.95 : 0.8),
                        ledColor.withValues(alpha: isBiting ? 0.5 : 0.3),
                        ledColor.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.25, 0.6, 1.0],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          // 번호 뱃지
          Container(
            width: badgeSize,
            height: badgeSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isBiting
                  ? Colors.greenAccent.withValues(alpha: 0.25)
                  : Colors.black.withValues(alpha: 0.6),
              border: Border.all(
                color: isBiting ? Colors.greenAccent : Colors.white30,
                width: 1,
              ),
            ),
            child: Text(
              '$number',
              style: TextStyle(
                color: Colors.white,
                fontSize: fontSize,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            isBiting ? '입질!' : '대기',
            style: TextStyle(
              color: isBiting ? Colors.greenAccent : Colors.white30,
              fontSize: (fontSize * 0.9).clamp(7.0, 11.0),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
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
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 10),
            // BLE 상태
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _connectedCentral != null
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth_searching,
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
            const SizedBox(height: 14),
            // 타이틀
            const Text(
              'KREFT 전자찌 테스트',
              style: TextStyle(
                color: Colors.amber,
                fontSize: 16,
                letterSpacing: 2,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '찌를 터치하면 입질 신호를 전송합니다',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 20),
            // 10개 가상 찌 그리드 (5열 × 2행)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const cols = 5;
                    const rows = 2;
                    const hGap = 10.0;
                    const vGap = 10.0;
                    final cellW = (constraints.maxWidth - hGap * (cols - 1)) / cols;
                    final cellH = (constraints.maxHeight - vGap * (rows - 1)) / rows;
                    final imgH = (cellH * 0.60).clamp(50.0, 160.0);
                    final glowS = (imgH * 0.22).clamp(12.0, 32.0);
                    final badgeS = (cellW * 0.38).clamp(16.0, 26.0);
                    final fontS = (badgeS * 0.48).clamp(8.0, 12.0);

                    return GridView.builder(
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        crossAxisSpacing: hGap,
                        mainAxisSpacing: vGap,
                        childAspectRatio: cellW / cellH,
                      ),
                      itemCount: 10,
                      itemBuilder: (context, index) => _buildVirtualFloat(
                        index,
                        imgHeight: imgH,
                        glowSize: glowS,
                        badgeSize: badgeS,
                        fontSize: fontS,
                      ),
                    );
                  },
                ),
              ),
            ),
            // 하단 센서 상태
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _isBite
                      ? Colors.redAccent.withValues(alpha: 0.5)
                      : Colors.white12,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.sensors,
                    size: 14,
                    color: _isBite ? Colors.redAccent : Colors.white38,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '가속도 센서: ${_isBite ? '입질 감지!' : '대기 중'}',
                    style: TextStyle(
                      color: _isBite ? Colors.redAccent : Colors.white38,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

