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
      appBar: AppBar(
        title: Text("App", style :TextStyle(fontSize: 47,color: Colors.white)),
        centerTitle: true,
        backgroundColor: Colors.orange,
        leading: Icon(Icons.menu, color : Colors.white),
        actions: [
          Icon(Icons.notifications, color: Colors.white )
        ],
         
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: .center,
          spacing: 28,
          children: [
            Icon(
              Icons.align_vertical_bottom_rounded,
              size: 125,
              color: Colors.purpleAccent,
            ),
            Container(
              width: 400,
              height: 100,
              color: const Color.fromARGB(255, 98, 193, 147),
              child: Center(
                child: Text("Hello", style: TextStyle(fontSize: 75)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

    // return Scaffold(
    //   appBar: AppBar(

    //     backgroundColor: Theme.of(context).colorScheme.inversePrimary,

    //     title: Text(widget.title),
    //   ),
    //   body: Center(

    //     child: Column(

    //       mainAxisAlignment: .center,
    //       children: [
    //         const Text('You have pushed the button this many times:'),
    //         Text(
    //           '$_counter',
    //           style: Theme.of(context).textTheme.headlineMedium,
    //         ),
    //       ],
    //     ),
    //   ),
    //   floatingActionButton: FloatingActionButton(
    //     onPressed: _incrementCounter,
    //     tooltip: 'Increment',
    //     child: const Icon(Icons.add),
    //   ),
    // );
  
