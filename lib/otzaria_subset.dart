/// מנוע ספרייה חלקית לאוצריא.
///
/// בונה תת-קבוצה של `seforim.db` לפי בחירת קטגוריות וספרים, מסנן קובצי
/// ‏`patch.db` של אוצריא לאותה תת-קבוצה, ומאמת את התוצאה מול hash לוגי
/// חלקי משלו.
///
/// **פעולות חוסמות:** `SubsetBuilder.build`, `PatchFilter.filter`
/// ו-`SubsetHasher.compute` סינכרוניות וכבדות (בנייה ממסד מלא נמשכת דקות).
/// אל תריץ אותן על ה-UI isolate — עטוף ב-`Isolate.run`, עם closure שקורא
/// לפונקציה **גלובלית** שמקבלת פרימיטיבים בלבד.
///
/// **מה החבילה הזאת אינה:** היא אינה מייצרת patches ואינה מחליפה את
/// `seforim_library_updater` — הגילוי, התכנון, ההורדה וההחלה נשארים שם.
/// היא מוסיפה שני דברים: גיזום, וסינון patch לפני ההחלה.
library;

export 'src/engine/index_invalidator.dart'
    show
        OtzariaIndexInvalidator,
        IndexInvalidationResult,
        IndexInvalidationException;
export 'src/engine/subset_pruner.dart'
    show SubsetPruner, SubsetPruneResult, SubsetPruneException;
export 'src/engine/removal_plan.dart' show RemovalSelection, keepSpecFor;
export 'src/engine/restore_plan.dart'
    show
        RestoreSelection,
        restoreSpecFor,
        restorableCatalog,
        specKeepsBook,
        keptBookIds,
        notKeptBookIds,
        importNarrowsOnly;
export 'src/engine/library_catalog.dart'
    show
        LibraryCatalog,
        CatalogCategory,
        CatalogBook,
        LibraryStats,
        readCatalog,
        readCatalogFromPath,
        readLibraryStats;
export 'src/engine/keep_set.dart'
    show KeepSet, CategoryKeepSet, categoryPruneWhere;
export 'src/engine/patch_filter.dart'
    show PatchFilter, PatchFilterReport, PatchFilterException;
export 'src/engine/subset_builder.dart'
    show SubsetBuilder, SubsetBuildResult, SubsetBuildException;
export 'src/engine/subset_hasher.dart' show SubsetHasher;
export 'src/engine/sqlite_uri.dart' show readOnlyUri, immutableUri;
export 'src/engine/subset_rebuilder.dart'
    show SubsetRebuilder, SubsetRebuildResult, SubsetRebuildException;
export 'src/engine/subset_resolver.dart' show SubsetResolver;
export 'src/engine/subset_updater.dart'
    show SubsetUpdater, SubsetUpdateResult, SubsetUpdateException;
export 'src/models/profile.dart' show SubsetProfile;
export 'src/models/selection_export.dart' show SelectionExport;
export 'src/models/subset_spec.dart'
    show SubsetSpec, SubsetPlan, SeveredLinkTarget, PatchKeepResolution;
export 'src/models/table_scope.dart'
    show
        ScopeKind,
        ParentRef,
        TableScope,
        kTableScopesInFkOrder,
        kTableScopeByName,
        kGlobalTables,
        scopeFor;
export 'src/store/machine_identity.dart' show MachineIdentity, MachineRegistry;
export 'src/store/otzaria_update_guard.dart'
    show OtzariaUpdateGuard, OtzariaUpdateSettings;
export 'src/store/profile_store.dart' show ProfileStore, ProfileStoreException;
