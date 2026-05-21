// ignore_for_file: prefer_final_fields
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'dart:async';

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
      home: const VirtualFloatScreen(),
    );
  }
}

class VirtualFloatScreen extends StatelessWidget {
  const VirtualFloatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const VirtualFloatHomeScreen();
  }
}

class VirtualFloatHomeScreen extends StatefulWidget {
  const VirtualFloatHomeScreen({super.key});

  @override
  State<VirtualFloatHomeScreen> createState() => _VirtualFloatHomeScreenState();
}

class _VirtualFloatHomeScreenState extends State<VirtualFloatHomeScreen> {
  // --- [블루투스 수신용 세팅값] ---
  Color _kemiColor = Colors.redAccent;
  final double _biteThreshold = 3.5; 
  double _baseBrightness = 1.0; // 앱에서 설정할 기본 밝기 (0.0 ~ 1.0)
  
  // --- [스마트 밝기 조절 상태값] ---
  double _autoDimFactor = 1.0; // 1.0(100%) -> 0.5(50%) -> 0.3(30%)
  Timer? _timer10s;
  Timer? _timer30s;
  
  bool _isBite = false; 
  StreamSubscription<UserAccelerometerEvent>? _accelerometerSubscription;

  @override
  void initState() {
    super.initState();
    _startSensor();
    _resetBrightnessTimers(); // 켜지자마자 타이머 작동 (100% 밝기 시작)
  }

  void _startSensor() {
    _accelerometerSubscription = userAccelerometerEventStream().listen((event) {
      if (event.y > _biteThreshold || event.y < -_biteThreshold) {
        if (!_isBite) _onBite();
      }
    });
  }

  // 10초, 30초 타이머 리셋 시스템
  void _resetBrightnessTimers() {
    _timer10s?.cancel();
    _timer30s?.cancel();
    
    setState(() {
      _autoDimFactor = 1.0; // 100% 밝기 복구
    });

    // 10초 동안 변화 없으면 50% 밝기로
    _timer10s = Timer(const Duration(seconds: 10), () {
      if (mounted) {
        setState(() {
          _autoDimFactor = 0.5;
        });
      }
    });

    // 30초 동안 변화 없으면 30% 밝기로
    _timer30s = Timer(const Duration(seconds: 30), () {
      if (mounted) {
        setState(() {
          _autoDimFactor = 0.3;
        });
      }
    });
  }

  // 입질 발생 시 구동되는 핵심 로직
  void _onBite() {
    setState(() {
      _isBite = true;
      _kemiColor = Colors.greenAccent; // 입질 시 보색(초록) 변경
    });
    
    _resetBrightnessTimers(); // 입질 시 밝기 100%로 강제 리셋

    // 2초 후 입질 종료 및 평상시 색상 복구
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
    _accelerometerSubscription?.cancel();
    _timer10s?.cancel();
    _timer30s?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    double finalAlpha = (_baseBrightness * _autoDimFactor).clamp(0.0, 1.0);
    int displayPercent = (finalAlpha * 100).toInt();

    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              "현재 케미 밝기: $displayPercent%",
              style: TextStyle(
                color: Colors.amber.withValues(alpha: finalAlpha.clamp(0.1, 1.0)), 
                letterSpacing: 2,
                fontWeight: FontWeight.bold,
                fontSize: 16
              ),
            ),
            const SizedBox(height: 50),
            
            // 💡 찌 전체 영역을 터치 영역으로 지정 (가상 입질)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (!_isBite) {
                  _onBite();
                }
              },
              child: Stack(
                alignment: Alignment.topCenter,
                children: [
                  // 1. 찌 상단 케미 (LED 발광부, 높이 35)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 500),
                    width: 6, 
                    height: 35, 
                    decoration: BoxDecoration(
                      color: _kemiColor.withValues(alpha: finalAlpha),
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: [
                        BoxShadow(
                          color: _kemiColor.withValues(alpha: _isBite ? finalAlpha : finalAlpha * 0.4),
                          blurRadius: _isBite ? 30 : 10 * finalAlpha,
                          spreadRadius: _isBite ? 12 : 1 * finalAlpha,
                        )
                      ],
                    ),
                  ),
                  
                  // 케미 아래로 찌탑, 몸통, 다리를 순서대로 배치
                  Padding(
                    padding: const EdgeInsets.only(top: 35), // 케미 바로 아래
                    child: Column(
                      children: [
                        // 연결부 마디
                        Container(width: 2, height: 5, color: Colors.grey[900]),
                        
                        // 💡 [핵심 보완] 블랙 & 레드 고시인성 패턴이 적용된 2배 긴 찌탑!
Container(
  width: 4, 
  height: 160, 
  decoration: const BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      // 💡 검은색과 빨간색을 교차 배치하여 마디가 눈에 쏙 들어오게 만들었습니다.
      colors: [
        Colors.black, Colors.redAccent,
        Colors.black, Colors.redAccent,
        Colors.black, Colors.redAccent,
        Colors.black, Colors.redAccent,
      ],
    ),
  ),
),
                        
                        // 3. 찌 메인 바디 (아래로 올수록 얇아지는 고정밀 역삼각 유선형 몸통)
                        CustomPaint(
                          size: const Size(26, 170), 
                          painter: FloatBodyPainter(),
                        ),
                        
                        // 4. 찌 하단 카본 다리
                        Container(
                          width: 1.5, 
                          height: 150, 
                          color: Colors.grey[700],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 50),
            
            Text(
              _isBite ? "🔴 입질 감지!" : "대기 중...",
              style: TextStyle(
                color: _isBite ? Colors.redAccent : Colors.white24,
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

// Representative floating body painter class
class FloatBodyPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    double width = size.width;
    double height = size.height;
    double centerX = width / 2;

    final paint = Paint()
      ..shader = const RadialGradient(
        center: Alignment(-0.2, -0.4), // 리얼한 입체감을 주는 하이라이트 위치 설정
        radius: 1.2,
        colors: [Color(0xFF555555), Color(0xFF161616), Color(0xFF0A0A0A)],
        stops: [0.0, 0.6, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, width, height))
      ..style = PaintingStyle.fill;

    final path = Path();
    
    // Calculate tapered body shape coordinates
    path.moveTo(centerX, 0); 
    // Create top rounding curve
    path.cubicTo(0, 0, 0, height * 0.2, 0, height * 0.2); 
    // Smooth tapering curve towards bottom
    path.quadraticBezierTo(0, height * 0.5, centerX - 0.75, height);
    path.lineTo(centerX + 0.75, height); // Connection point to leg
    path.quadraticBezierTo(width, height * 0.5, width, height * 0.2);
    path.cubicTo(width, height * 0.2, width, 0, centerX, 0);
    path.close();

    canvas.drawPath(path, paint);

    // Subtle golden edge line
    final goldPaint = Paint()
      ..color = Colors.amber.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    canvas.drawPath(path, goldPaint);

    // Vertical brand text in center
    final textPainter = TextPainter(
      text: const TextSpan(
        text: "K\nR\nE\nF\nT",
        style: TextStyle(color: Colors.amber, fontSize: 6.5, fontWeight: FontWeight.bold, height: 1.4),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(centerX - (textPainter.width / 2), height * 0.2));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}