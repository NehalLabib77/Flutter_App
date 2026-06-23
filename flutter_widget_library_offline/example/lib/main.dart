import 'package:flutter/material.dart';
import 'package:flutter_widget_library_offline/flutter_widget_reference.dart';

void main() => runApp(const WidgetLibraryApp());

class WidgetLibraryApp extends StatelessWidget {
  const WidgetLibraryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flutter Widget Library',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const WidgetLibraryPage(),
    );
  }
}

class WidgetLibraryPage extends StatefulWidget {
  const WidgetLibraryPage({super.key});

  @override
  State<WidgetLibraryPage> createState() => _WidgetLibraryPageState();
}

class _WidgetLibraryPageState extends State<WidgetLibraryPage> {
  String query = '';
  String? category;

  List<String> get categories => flutterWidgetReference
      .map((item) => item.category)
      .toSet()
      .toList()
    ..sort();

  List<WidgetReference> get visibleItems {
    final normalized = query.trim().toLowerCase();
    return flutterWidgetReference.where((item) {
      final matchesCategory = category == null || item.category == category;
      final matchesQuery = normalized.isEmpty ||
          item.name.toLowerCase().contains(normalized) ||
          item.description.toLowerCase().contains(normalized);
      return matchesCategory && matchesQuery;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final items = visibleItems;
    return Scaffold(
      appBar: AppBar(title: const Text('Flutter Widget Library')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              onChanged: (value) => setState(() => query = value),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                hintText: 'Search: list, form, animation, button...',
              ),
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FilterChip(
                    label: const Text('All'),
                    selected: category == null,
                    onSelected: (_) => setState(() => category = null),
                  ),
                ),
                for (final item in categories)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: FilterChip(
                      label: Text(item),
                      selected: category == item,
                      onSelected: (_) => setState(
                        () => category = category == item ? null : item,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? const Center(child: Text('No matching widgets found.'))
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return ListTile(
                        title: Text(item.name),
                        subtitle: Text(item.description),
                        trailing: Text(
                          item.category,
                          textAlign: TextAlign.end,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
