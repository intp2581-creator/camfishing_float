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

// 색상 프리셋 — 기본색 + 입질 시 변색 규칙 (컨트롤러 앱과 동일하게 유지)
// 빨강→파랑, 초록→빨강, 파랑→빨강, 노랑→초록, 핑크→파랑
class ColorPreset {
  final String name;
  final int r, g, b;      // 기본색
  final int br, bg, bb;   // 입질 시 변색
  const ColorPreset(this.name, this.r, this.g, this.b, this.br, this.bg, this.bb);
  Color get base => Color.fromARGB(255, r, g, b);
  Color get bite => Color.fromARGB(255, br, bg, bb);
}

const List<ColorPreset> kColorPresets = [
  ColorPreset('레드',   255, 0,   0,     0,   200, 255), // 빨강 → 파랑
  ColorPreset('그린',   0,   255, 100,   255, 0,   0),   // 초록 → 빨강
  ColorPreset('블루',   0,   200, 255,   255, 0,   0),   // 파랑 → 빨강
  ColorPreset('옐로우', 255, 200, 0,     0,   255, 100), // 노랑 → 초록
  ColorPreset('핑크',   255, 0,   150,   0,   200, 255), // 핑크 → 파랑
];

// 수신한 기본색(RGB)에 가장 가까운 프리셋을 찾아 입질 변색을 결정
ColorPreset nearestPreset(int r, int g, int b) {
  ColorPreset best = kColorPresets.first;
  int bestDist = 1 << 30;
  for (final p in kColorPresets) {
    final d = (p.r - r) * (p.r - r) +
              (p.g - g) * (p.g - g) +
              (p.b - b) * (p.b - b);
    if (d < bestDist) { bestDist = d; best = p; }
  }
  return best;
}

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
  // 기본색 RGB — 컨트롤러의 COLOR 명령으로 갱신, 기본값은 레드(255,0,0)
  int _baseR = 255, _baseG = 0, _baseB = 0;
  Color get _baseColor => Color.fromARGB(255, _baseR, _baseG, _baseB);
  Color get _biteColor => nearestPreset(_baseR, _baseG, _baseB).bite;
  Color _kemiColor = const Color.fromARGB(255, 255, 0, 0);
  // 위치 확인용 깜빡임 상태 (컨트롤러 BLINK 명령)
  bool _blinking = false;
  int _blinkColorIdx = 0;   // 깜빡임 5색 순환 인덱스
  double _biteThreshold = 3.5;
  double _baseBrightness = 1.0;
  double _autoDimFactor = 1.0;
  bool _isBite = false;
  bool _isOn = true;
  bool _variColor = true;    // 입질 시 변색 ON/OFF (컨트롤러 VARI 명령)
  bool _alertPhone = true;   // 입질 시 폰 알림 ON/OFF (컨트롤러 ALERT 명령)

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
          _baseR = int.tryParse(parts[0]) ?? 255;
          _baseG = int.tryParse(parts[1]) ?? 0;
          _baseB = int.tryParse(parts[2]) ?? 0;
          _kemiColor = _baseColor;   // 센서 표시색도 기본색으로 동기화
        }
      } else if (cmd.startsWith('BRIGHTNESS:')) {
        _baseBrightness = double.tryParse(cmd.substring(11)) ?? 1.0;
      } else if (cmd.startsWith('SENSITIVITY:')) {
        _biteThreshold = double.tryParse(cmd.substring(12)) ?? 3.5;
      } else if (cmd.startsWith('VARI:')) {
        _variColor = (int.tryParse(cmd.substring(5)) ?? 1) != 0;
      } else if (cmd.startsWith('ALERT:')) {
        _alertPhone = (int.tryParse(cmd.substring(6)) ?? 1) != 0;
      }
    });
  }

  // 위치 확인용 깜빡임 (컨트롤러에서 BLINK 명령 수신 시)
  // 5색(빨·초·파·노·핑) 빠르게 순환 → 낮에도 잘 보이게
  void _startBlink() {
    int count = 0;
    setState(() { _blinking = true; _blinkColorIdx = 0; });
    Timer.periodic(const Duration(milliseconds: 150), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (count >= 18) {
        timer.cancel();
        if (mounted) setState(() { _blinking = false; _blinkColorIdx = 0; });
        return;
      }
      setState(() => _blinkColorIdx = (_blinkColorIdx + 1) % 5);
      count++;
    });
  }

  void _startSensor() {
    _accelSub = userAccelerometerEventStream().listen((event) {
      // 3축 중 어느 하나라도 임계값 초과하면 입질 감지 (폰 방향 무관)
      if ((event.x.abs() > _biteThreshold ||
              event.y.abs() > _biteThreshold ||
              event.z.abs() > _biteThreshold) &&
          !_isBite &&
          _isOn) {
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
      _kemiColor = _variColor ? _biteColor : _baseColor;   // 변색 모드일 때만 변색
    });
    _resetBrightnessTimers();

    // BLE로 입질 신호 송신 (알림 모드일 때만)
    if (_alertPhone && _bleReady && _biteChar != null && _connectedCentral != null) {
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
          _kemiColor = _baseColor;   // 기본색으로 복귀
        });
        _resetBrightnessTimers(); // 입질 후 기본색 100%로 재시작
      }
    });
  }

  // 단일 찌 위젯 — 컨트롤러가 보낸 색상/밝기/ON·OFF를 그대로 반영
  Widget _buildFloat({required double imgHeight}) {
    // LED 색: 깜빡임 중이면 흰↔기본, 입질+변색모드면 프리셋 변색, 아니면 기본색. OFF면 소등.
    final biteVisual = _isBite && _variColor;   // 변색 모드일 때만 입질 표현
    final ledColor = !_isOn
        ? Colors.grey.shade800
        : _blinking
            ? kColorPresets[_blinkColorIdx].base   // 5색 순환 (낮에도 잘 보이게)
            : (biteVisual ? _biteColor : _baseColor);
    // 밝기: 컨트롤러 밝기 × 자동 디밍 (변색 입질·깜빡임 중엔 최대)
    final brightness = (biteVisual || _blinking)
        ? 1.0
        : (_baseBrightness * _autoDimFactor).clamp(0.0, 1.0);
    final glow = (imgHeight * (biteVisual ? 0.32 : 0.24)).clamp(20.0, 140.0);
    final on = _isOn;

    return GestureDetector(
      onTap: _onBite, // 터치로도 입질 신호 전송 (테스트용)
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            alignment: Alignment.topCenter,
            clipBehavior: Clip.none,
            children: [
              Image.asset(
                'assets/images/float_kreft.png',
                height: imgHeight,
                fit: BoxFit.fitHeight,
              ),
              // LED 글로우 — 찌탑 상단
              Positioned(
                top: -(glow / 2),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: glow,
                  height: glow,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        Colors.white.withValues(alpha: on ? brightness : 0.0),
                        ledColor.withValues(alpha: on ? brightness * 0.85 : 0.0),
                        ledColor.withValues(alpha: on ? brightness * 0.4 : 0.0),
                        ledColor.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.25, 0.6, 1.0],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            !_isOn ? '소등(OFF)' : (_isBite ? '입질!' : '대기'),
            style: TextStyle(
              color: !_isOn
                  ? Colors.white30
                  : (biteVisual ? _biteColor : Colors.white60),
              fontSize: 18,
              fontWeight: FontWeight.bold,
              letterSpacing: 1,
            ),
          ),
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
              '흔들거나 찌를 터치하면 입질 신호를 전송합니다',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 20),
            // 단일 찌 — 화면 중앙
            Expanded(
              child: Center(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final imgH =
                        (constraints.maxHeight - 80).clamp(120.0, 520.0);
                    return _buildFloat(imgHeight: imgH);
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

