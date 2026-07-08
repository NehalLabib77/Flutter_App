A Scaffold is the usual starting point for a Material-style screen.

Scaffold(
  appBar: AppBar(),
  body: const SizedBox(),
  drawer: const Drawer(),
  floatingActionButton: FloatingActionButton(),
  bottomNavigationBar: const NavigationBar(
    destinations: [],
  ),
);

appBar: top navigation/header area.
body: main content of the screen.
drawer: side menu. 
floatingActionButton: circular action button, usually bottom-right.
bottomNavigationBar: navigation at the bottom.

Important to remember:

Normally use one main Scaffold per screen/page.
Scaffold does not use child: directly. It uses named properties such as body: and appBar:.
The body starts at the top-left by default; wrap it in Center to center content.

Scafold is covered 

AppBar is the bar at the top of a screen. It is normally placed inside Scaffold.appBar.
title Usually, it is a Text widget.
title: const Text('Dashboard')

Body:

Scaffold(
  body: Center(
    child: Text('Welcome'),
  ),
);

scafold can contain one body 
body accepts one widget.
That one widget can contain many other widgets, such as a Column, ListView, or Container.
For a scrollable page, often use ListView or SingleChildScrollView.

 body covered 


 Child & Children 

 child Used when a widget accepts only one widget.
 Center(
  child: Text('Hello'),
);

Other widgets that commonly use child:

Center
Container
Padding
SizedBox
Expanded
Card

children

Used when a widget accepts multiple widgets in a list.

Column(
  children: [
    Text('Name'),
    Text('Email'),
    Text('Phone'),
  ],
);

Column
Row
Stack
ListView

Important to remember

child: = one widget.
children: [] = multiple widgets.
Flutter screens are a widget tree: one widget contains another widget, which can contain more widgets.

children covered 

center 
Important to remember

Center accepts only one child.
It centers both horizontally and vertically.
It does not change text alignment inside a Text; it changes where the whole child widget sits.

center covered 


text style 
Text(
  'Profile',
  style: TextStyle(
    fontSize: 22,
    color: Colors.blue,
    fontWeight: FontWeight.bold,
    fontStyle: FontStyle.italic,
    letterSpacing: 1.2,
  ),
)

common properties 

| Property        | What it does                         |
| --------------- | ------------------------------------ |
| `fontSize`      | Changes text size                    |
| `color`         | Changes text color                   |
| `fontWeight`    | Makes text light, normal, bold, etc. |
| `fontStyle`     | Normal or italic text                |
| `fontFamily`    | Changes font family                  |
| `letterSpacing` | Space between letters                |
| `wordSpacing`   | Space between words                  |
| `decoration`    | Underline, line-through, etc.        |
| `height`        | Line height / vertical spacing       |

Important to remember

Use app-wide themes for repeated text styles instead of manually styling every Text.
Avoid very small text and low-contrast color combinations.
TextStyle is passed through the style: property of Text.

text style is covered

Container

Container is a flexible box widget. It can control size, color, padding, margin, alignment, decoration, and more.

Container(
  width: 200,
  height: 100,
  padding: const EdgeInsets.all(16),
  margin: const EdgeInsets.all(12),
  color: Colors.blue,
  child: const Text('Inside a container'),
)

| Property          | What it does                                 |
| ----------------- | -------------------------------------------- |
| `child`           | Widget placed inside                         |
| `width`, `height` | Sets size                                    |
| `padding`         | Space inside the box                         |
| `margin`          | Space outside the box                        |
| `alignment`       | Positions the child inside                   |
| `color`           | Background color                             |
| `decoration`      | Borders, rounded corners, gradients, shadows |
| `constraints`     | Controls minimum/maximum size                |

Important to remember

A Container accepts only one child.
Do not use both color: and decoration: with a color at the same time; put the color inside BoxDecoration when using decoration.
Use Padding, SizedBox, or Align directly when you only need one simple purpose. Avoid using Container everywhere.

Icon 

Important to remember

Icon only displays the icon.
Use IconButton when the icon should respond to taps.
Most built-in icons come from the Icons class, such as Icons.home, Icons.menu, and Icons.search.


Scaffold  → Complete screen structure
AppBar    → Top bar of screen
body      → Main screen area
child     → One widget
children  → Multiple widgets
Center    → Centers one widget
Text      → Displays text
TextStyle → Designs text
Container → Box with size, color, padding, margin
Row       → Horizontal layout
Column    → Vertical layout
ListView  → Scrollable list
Stack     → Overlapping widgets
Icon      → Shows symbol/icon
mainAxisAlignment → Spacing on Row/Column main direction



Bare minimum for main.dart 

import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('Hello Flutter'),
        ),
      ),
    );
  }
}

home widget means home screen 


colors to access all colors ....accent mean to access all that color property 

if i have hex code we can use color (oxff(hex code)to int code )


to include image we can create assest file 
image in png it is a class 

mainaxisalignment 
MainAxisAlignment controls the main direction.

MainAxisAlignment.start        // beginning
MainAxisAlignment.center       // middle
MainAxisAlignment.end          // end
MainAxisAlignment.spaceBetween // space between items
MainAxisAlignment.spaceAround  // space around items
MainAxisAlignment.spaceEvenly  // equal space everywhere


CrossAxisAlignment controls the opposite direction.

CrossAxisAlignment.start   // left in Column, top in Row
CrossAxisAlignment.center  // center
CrossAxisAlignment.end     // right in Column, bottom in Row
CrossAxisAlignment.stretch // stretch to fill opposite direction