import 'dart:async';

import 'package:file_selector/file_selector.dart';

import 'package:flutter/material.dart';

import '../main.dart';
import '../state/app_settings.dart';
import '../theme.dart';
import '../widgets/disclaimer.dart';
import '../widgets/update_guard.dart';

/// הגדרות. שתי שאלות בלבד — כל השאר נגזר.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final settings = state.settings;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: ListView(
          padding: const EdgeInsets.all(32),
          children: [
            Text('הגדרות', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const _IconBadge(
                        icon: Icons.folder_rounded,
                        color: AppColors.seed,
                      ),
                      title: Text(
                        'מיקום הספרייה',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        state.paths.libraryDbPath ?? 'לא נמצאה ספריית אוצריא',
                      ),
                      trailing: TextButton(
                        onPressed: () => _pickDb(context),
                        child: const Text('שינוי'),
                      ),
                    ),
                    if (settings.libraryDbPathOverride != null)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: _IconBadge(
                          icon: Icons.restore_rounded,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        title: const Text('לחזור לאיתור אוטומטי'),
                        trailing: TextButton(
                          onPressed: () => state.saveSettings(
                            settings.copyWith(clearOverride: true),
                          ),
                          child: const Text('איפוס'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const _IconBadge(
                          icon: Icons.sync_rounded,
                          color: AppColors.accent,
                        ),
                        const SizedBox(width: 14),
                        Text(
                          'מקור עדכונים',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                    RadioGroup<UpdateSource>(
                      groupValue: settings.updateSource,
                      onChanged: (value) => state.saveSettings(
                        settings.copyWith(updateSource: value),
                      ),
                      child: const Column(
                        children: [
                          RadioListTile<UpdateSource>(
                            value: UpdateSource.internet,
                            title: Text('עדכונים מהאינטרנט'),
                          ),
                          RadioListTile<UpdateSource>(
                            value: UpdateSource.folder,
                            title: Text('עדכונים מתיקייה'),
                            subtitle: Text('למחשב בלי חיבור לאינטרנט'),
                          ),
                        ],
                      ),
                    ),
                    if (settings.updateSource == UpdateSource.folder)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const _IconBadge(
                          icon: Icons.folder_open_rounded,
                          color: AppColors.accent,
                        ),
                        title: Text(
                          settings.updateFolder ?? 'לא נבחרה תיקייה',
                        ),
                        trailing: TextButton(
                          onPressed: () => _pickFolder(context),
                          child: const Text('בחירה'),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            UpdateGuardBanner(
              settings: state.otzariaUpdates,
              onRecheck: () => unawaited(state.refreshOtzaria()),
            ),
            const DisclaimerFooter(),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDb(BuildContext context) async {
    final state = AppScope.of(context);
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'ספריית אוצריא', extensions: ['db']),
      ],
    );
    if (file == null) return;
    await state.saveSettings(
      state.settings.copyWith(libraryDbPathOverride: file.path),
    );
  }

  Future<void> _pickFolder(BuildContext context) async {
    final state = AppScope.of(context);
    final dir = await getDirectoryPath();
    if (dir == null) return;
    await state.saveSettings(state.settings.copyWith(updateFolder: dir));
  }
}

/// תג אייקון קטן וצבעוני, כמו ב-[HomeScreen] — מסמן ויזואלית מה הסעיף.
class _IconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _IconBadge({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(icon, color: color),
      );
}
