import 'package:flutter/material.dart';

class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          //Colors.lightBlueAccent.shade700
          Color(0xffFAFAFA),
      body: Column(
        mainAxisAlignment: .spaceBetween,
        crossAxisAlignment: .center,
        children: [
          Align(alignment: AlignmentGeometry.topRight,child: Image.asset("assets/image1.png",),),





          
        Align(alignment: AlignmentGeometry.bottomLeft, child: Image.asset("assets/Vector-2.png"),)
      ,]),
    );
  }
}
