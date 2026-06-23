import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.deepPurple)),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  String msg = " Hello";
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // body: Center(
      //   child: Column(

      //     children: [
      //       Row(),
      //       Stack(),
      //       ListView(),
      //       Column(),

      //     Text('Hello2'),
      //   ],),
      // ),
      
      appBar: AppBar(),
      body: Text("This is a good msg",
        textAlign: TextAlign.center,
        maxLines: 24,
        overflow: TextOverflow.ellipsis,
      ),
      drawer: const Drawer(),
      floatingActionButton: FloatingActionButton(onPressed: () {}),
      bottomNavigationBar: NavigationBar(
        destinations: [
          NavigationDestination(
            icon: Icon(Icons.access_alarm),
            selectedIcon: Icon(Icons.alarm),
            label: 'access_alarm',
          ),

          NavigationDestination(
            icon: Icon(Icons.abc_sharp),
            selectedIcon: Icon(Icons.abc),
            label: 'abc_sharp',
          ),
        ],
      ),
    );
  }
}
