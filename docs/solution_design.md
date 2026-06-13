# Smart Data Migration Framework — Solution Design

> Salesforce Technical Architecture · API v66.0 · No namespace
> Architecture diagram: `docs/smart_data_migration_architecture.svg`
> Data model reference: `docs/data_model.md`

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [Solution Overview](#3-solution-overview)
4. [Architecture Walkthrough](#4-architecture-walkthrough)
   - 4.1 Source Extraction
   - 4.2 Validation Engine
   - 4.3 Relationship Resolver
   - 4.4 Bulk Load Engine
   - 4.5 Progress Tracker
   - 4.6 Rollback Layer
5. [Core Capabilities In Depth](#5-core-capabilities-in-depth)
6. [Data Model Summary](#6-data-model-summary)
7. [Technical Implementation](#7-technical-implementation)
8. [Non-Functional Characteristics](#8-non-functional-characteristics)
9. [Deployment and Configuration](#9-deployment-and-configuration)
10. [What This Framework Achieves](#10-what-this-framework-achieves)

---

## 1. Executive Summary

The Smart Data Migration Framework is a Salesforce-native solution for loading large volumes of data from any external source into a Salesforce org with **complete predictability, full visibility, and guaranteed recoverability**. It eliminates the six failure modes that make standard data migrations brittle — silent data loss, broken relationships, no recovery, no visibility, no rollback, and late-discovered data quality problems.

The framework runs entirely inside Salesforce. There is no middleware, no external tooling requirement, and no dependency on third-party ETL platforms. Every migration is managed through a purpose-built data model, executed by Apex, and monitored through an LWC dashboard.

The defining principle is: **nothing reaches the database unless it has already been proven safe to load**. Clients see a complete field-by-field, row-by-row error report before a single DML statement is committed.

---

## 2. Problem Statement

Every Salesforce data migration project carries the same set of recurring, well-understood risks. The industry has accepted these risks for years because the standard tools — Data Loader, Bulk API CSV uploads, and manual Apex scripts — were not built to prevent them.

### 2.1 Silent Data Loss

Standard bulk loaders operate in all-or-nothing batch mode by default. When one record in a batch of 200 fails, the entire batch is rolled back. The other 199 records are discarded without any indication that they were ever attempted. At scale, this means thousands of records silently disappear from the loaded dataset with no error trail.

**Consequence:** Migrations appear to complete but the target org is missing data. The gap is often only discovered weeks later during UAT.

### 2.2 Broken Relationships

Salesforce relationships (lookup fields, master-detail fields) reference record IDs — not external identifiers. Loading Contacts before their parent Accounts exist produces foreign key failures for every Contact record. The problem compounds across complex object models: Opportunities depend on Accounts; Opportunity Line Items depend on Opportunities and Products; custom objects have their own hierarchies.

Most tools require manual specification of load order, and getting it wrong — even once — causes cascading failures that are slow and painful to trace.

**Consequence:** Failed loads require manual analysis of the dependency chain, manual reordering, and a full re-run from the beginning.

### 2.3 No Recovery on Failure

When a migration job times out, hits a governor limit, or encounters an unexpected error at batch 47 of 200, the only option is to restart from row one. All work up to that point is lost. For large migrations — hundreds of thousands of records — this means hours of work wasted on every failure, with no guarantee the same failure will not happen again at the same point.

**Consequence:** Large migrations become a guessing game of how many attempts it will take to get all the way through.

### 2.4 No Visibility During Load

The client asks "how is it going?" and the honest answer is "I don't know yet." Standard tools provide no real-time feedback during execution. The only signal is a completion notification or an error email, neither of which tells you what happened to specific records.

**Consequence:** Migration windows extend beyond scheduled maintenance periods because nobody knows when they will actually finish.

### 2.5 No Undo

Something goes wrong mid-migration — duplicate records, wrong field values, or corrupted relationships — and the client says "put everything back." Standard tools provide no rollback capability. The only option is to manually identify and delete thousands of newly inserted records, a process that is time-consuming, error-prone, and sometimes impossible without disrupting live data.

**Consequence:** A failed migration can leave the target org in a permanently degraded state.

### 2.6 Data Quality Discovered Too Late

Picklist value mismatches, required fields left blank, text values longer than their target field's maximum length, invalid date formats — these problems only surface during the load itself, mid-project, when the client has already scheduled the cutover. Fixing source data at this point means rescheduling the cutover, re-extracting the source, and re-running the entire validation cycle.

**Consequence:** Late-stage data quality issues are the single most common cause of migration project overruns.

---

## 3. Solution Overview

The Smart Data Migration Framework addresses each failure mode with a dedicated architectural layer. The solution is not a single Apex class or a clever bulk API trick — it is a complete system with a data model, an execution engine, a validation pipeline, and a recovery subsystem that all work together.

```
┌─────────────────────────────────────────────────────────┐
│  Problem                 │  Framework response           │
├─────────────────────────────────────────────────────────┤
│  Silent data loss        │  allOrNone=false per batch    │
│                          │  + row-level error log        │
├─────────────────────────────────────────────────────────┤
│  Broken relationships    │  Topological sort of objects  │
│                          │  + external ID resolution     │
├─────────────────────────────────────────────────────────┤
│  No recovery on failure  │  Checkpoint per batch         │
│                          │  + resume from last success   │
├─────────────────────────────────────────────────────────┤
│  No visibility           │  LWC dashboard with live      │
│                          │  counters and ETA             │
├─────────────────────────────────────────────────────────┤
│  No undo                 │  Rollback log of every        │
│                          │  inserted ID, reverse delete  │
├─────────────────────────────────────────────────────────┤
│  Late data quality       │  Dry-run validation against   │
│                          │  live schema before any DML   │
└─────────────────────────────────────────────────────────┘
```

The framework exposes one primary entry point: a `MigrationJob__c` record. Everything else — configuration, execution, monitoring, and recovery — flows from that single record.

---

## 4. Architecture Walkthrough

The architecture is a six-layer pipeline. Each layer has a single, well-defined responsibility. Layers communicate through the custom data model — not through direct method calls or shared state — which means any layer can be re-run independently without restarting the whole pipeline.

### 4.1 Source Extraction

**Supported sources:** CSV/Excel files, legacy CRM exports, external REST APIs, another Salesforce org via the Metadata/Bulk API.

The source layer is intentionally thin. Its only job is to deliver a structured row dataset to the validation engine. Source-specific adapters implement a common interface, so the rest of the framework never needs to know where the data came from.

Source records are not mutated. The framework reads the source, validates it, maps it, and loads it — the original source data is never modified or deleted.

### 4.2 Validation Engine

The validation engine is the framework's most important safety layer. It runs against the live target org's field metadata using Apex Describe calls, not against a cached schema definition. This means it catches problems that only exist in this specific org — custom picklist values added last month, field length changes from a recent configuration update, required fields enforced by validation rules.

The engine performs three categories of check:

**Schema validation** compares each source value against the target field's metadata: type compatibility (is a date being loaded into a Date field in the correct format?), length (does the text value fit within the field's character limit?), and format (is the phone number parseable?).

**Duplicate detection** uses the configured external ID field to identify records that already exist in the target org. For upsert-mode migrations this is informational. For insert-mode migrations this is a hard error — attempting to insert a duplicate external ID will fail at the database level.

**Required field checking** validates that every field marked required in Salesforce — either system-enforced or enforced by validation rules — has a non-null, non-empty value in the source row. This check also covers picklist values: if a source row contains `"Active"` but the target field only allows `"Active__c"`, the engine flags it with the full list of valid values as the suggested fix.

Every error is written to `MigrationRowError__c` with four pieces of information: the row number, the field name, the offending value, and a machine-generated suggested fix. The validation report is the complete, structured output of this pass.

**The critical guarantee:** the validation engine runs before any DML is committed. In dry-run mode (`MigrationJob__c.IsDryRun__c = true`), it runs and produces the full report with zero writes to the target org. In standard mode, a validation pass runs first, and only if it produces zero errors does the load proceed.

### 4.3 Relationship Resolver

The relationship resolver determines the correct load order for all objects in the migration and builds the translation table that connects legacy parent IDs to live Salesforce IDs.

**Dependency graph construction.** The resolver calls Salesforce's DescribeGlobal and DescribeSObject APIs to identify all lookup and master-detail fields between the objects being migrated. It then constructs a directed acyclic graph (DAG) where an edge from Object A to Object B means "A must be loaded before B." The resolver runs a topological sort on this graph and writes the result as `LoadOrder__c` on each `MigrationObjectConfig__c` record. The bulk load engine processes objects strictly in ascending `LoadOrder__c` sequence.

**Pre-seeded rules.** Common Salesforce relationships (Account → Contact, Account → Opportunity, Pricebook2 → PricebookEntry) are pre-seeded in `MigrationObjectRule__mdt` so the resolver does not need to discover them from scratch. Custom objects and non-standard relationships are detected dynamically.

**External ID mapping.** As each parent object batch commits, the framework writes a `MigrationRecordLog__c` record for every successfully inserted or upserted record, capturing the legacy source ID alongside the newly assigned Salesforce ID. When the engine begins processing child records, it resolves every parent lookup field by querying this log. The child row's legacy parent ID is replaced with the live Salesforce ID before the DML call.

**Self-referential objects.** Objects that reference themselves (Contact.ReportsToId → Contact, Account.ParentId → Account, User.ManagerId → User) cannot be fully loaded in a single pass — a Contact that reports to another Contact cannot have its `ReportsToId` populated until both records exist. The resolver detects these and sets `HasSelfReference__c = true` on the object config. The bulk load engine then applies a two-pass strategy: first pass loads all records with the self-reference field null; second pass runs an update-only batch that populates the self-reference fields using the now-complete ID map.

### 4.4 Bulk Load Engine

The bulk load engine is the execution heart of the framework. It processes records in 200-row batches using Apex Queueable jobs chained in sequence.

**Batch chunking.** The engine divides the source dataset into fixed 200-row chunks. The size is configurable but defaults to 200 — the maximum that keeps the framework safely within Salesforce's DML rows-per-transaction governor limit, leaving headroom for trigger-fired DML (workflow updates, platform event publishes, rollup recalculations).

**Upsert and insert modes.** When a migration job is configured in `Upsert` mode, every batch uses `Database.upsert()` with the configured external ID field. This means the same job can be run multiple times safely — records that already exist are updated rather than duplicated. For net-new migrations with no pre-existing data, `Insert` mode uses `Database.insert()` and treats duplicate external IDs as hard errors.

**Partial success.** All DML calls use `allOrNone = false`. This means that when record 47 of 200 fails with a Salesforce error, records 1–46 and 48–200 succeed and are committed. The engine captures the exact Salesforce error string from the `Database.SaveResult` for the failed record and writes it to `MigrationRowError__c` with `Phase__c = 'DML'`. No good record is ever discarded because of a bad neighbour.

**Governor limit safety.** Field mappings and object configuration are loaded once per batch invocation and cached in Apex instance variables — never queried per row. Parent ID resolution uses Platform Cache as the primary lookup with `MigrationRecordLog__c` SOQL as the fallback, ensuring the heap stays well within the 12MB async limit even for parent datasets with 100,000+ records.

### 4.5 Progress Tracker

After every batch completes, the engine updates three sets of counters atomically:

- `MigrationBatch__c` — `SuccessCount__c`, `FailureCount__c`, `DurationSeconds__c`
- `MigrationObjectConfig__c` — `LoadedCount__c`, `FailedCount__c`, `SkippedCount__c`
- `MigrationJob__c` — `LoadedCount__c`, `FailedCount__c`, `PercentComplete__c`, `EstimatedCompletionAt__c`

The LWC progress dashboard queries `MigrationJob__c` and its child `MigrationBatch__c` records directly. Records loaded, failed, skipped, percentage complete, and estimated time remaining are all live values derived from these counters — no polling a black-box process, no waiting for a completion email.

**Checkpointing.** After each successfully committed batch, the engine sets `IsCheckpoint__c = true` on that batch and `false` on all previous batches. `MigrationJob__c.LastCompletedBatchSequence__c` is updated to the batch's global sequence number. If the job is interrupted at any point — by a governor limit timeout, a server error, or an explicit pause — the next execution queries for the checkpoint and picks up from the following batch. A 100,000-record migration that fails at batch 499 of 500 resumes at batch 500, not at row one.

### 4.6 Rollback Layer

The rollback layer is the framework's safety net for the unexpected — and it exists because "unexpected" is always a possibility in production migrations.

**Rollback log.** Every record written to the target org during the migration is captured in `MigrationRecordLog__c`. The log stores the Salesforce ID, the legacy source ID, the object type, and the `LoadOrder__c` of the object at the time of insert. The `LoadOrder__c` field is what makes reverse-order deletion possible: if Accounts have `LoadOrder = 1` and Contacts have `LoadOrder = 2`, rollback deletes Contacts first (highest load order), then Accounts. Referential integrity is maintained in both directions.

**One-click rollback.** Creating a `MigrationRollback__c` record and setting its status to `Pending` triggers an Apex Batchable job that reads all `Active` records from the rollback log in descending `LoadOrder__c` order and executes `Database.delete()` batches against the target org. Progress is tracked on the `MigrationRollback__c` record. Records that are successfully deleted are marked `RollbackStatus__c = 'Deleted'` on the log. Records that cannot be deleted (already deleted externally, locked by a process, etc.) are flagged `DeleteFailed` with the error captured in the rollback job's `ErrorLog__c`.

**Dry-run mode.** With `IsDryRun__c = true` on the job, the entire validation engine runs against the live org schema. Every `MigrationRowError__c` record that would be generated by a live run is generated. Every validation report is produced. The `ValidationSummary__c` on the job is populated with a human-readable summary. Zero DML is committed to the target org. The client receives a complete picture of what the migration would do before anything is touched.

---

## 5. Core Capabilities In Depth

### 5.1 Zero Surprise Failures

Every row is validated against the live schema before any DML is committed. "Live schema" means Salesforce Describe results queried at the time of validation — not a cached copy, not a configuration file. If someone added a required field yesterday, the validation engine knows about it today.

The validation report produced before the load begins is the contract between the framework and the client: "if you fix these errors in your source data and re-run, nothing will fail." After the validation pass returns zero errors, the load proceeds with the guarantee that every row that enters the bulk load engine is structurally valid.

DML-phase errors can still occur — trigger validation rules, duplicate rules, sharing rules, record-level security — but schema-level failures are entirely eliminated before the load begins.

### 5.2 Correct Load Order, Automatically

The dependency graph is constructed by querying Salesforce metadata, not by reading a configuration file. The client does not need to know that Opportunity Line Items depend on Opportunities which depend on Accounts. The resolver figures this out by traversing the DescribeSObject results for every object in the migration scope.

The topological sort algorithm processes objects in dependency order. In a cycle-free graph (Salesforce's standard objects form a cycle-free graph for migration purposes, with the exception of self-referential lookups which are handled separately), there is always a valid load order and the resolver always finds it.

The external ID mapping flows automatically from parent batches to child rows. There is no manual step where a developer exports Account IDs and pastes them into a Contact CSV. The `MigrationRecordLog__c` record written after each Account batch becomes the lookup table that the Contact batch reads from.

### 5.3 Partial Success Per Batch

Standard Salesforce DML in Apex defaults to all-or-nothing. One bad record cancels the entire transaction. The framework overrides this for every batch with `allOrNone = false`.

The consequence is that a bad row in position 47 does not affect positions 1–46 or 48–200. The 199 good records are committed. Position 47 generates a `MigrationRowError__c` record with the Salesforce error message, the offending row number, the source external ID, and — where the framework can determine it — a suggested fix.

This behaviour is applied at every level. A batch where all 200 records fail still completes — it just sets `Status__c = 'Failed'` rather than `'Success'` or `'PartialSuccess'`. The job continues to the next batch. No good data is held hostage by bad data.

### 5.4 Resumable on Any Failure

The checkpoint system means that any interruption — deliberate pause, governor limit timeout, transaction rollback from an unhandled exception — leaves the job in a known, resumable state.

After every committed batch, one field changes on the job: `LastCompletedBatchSequence__c`. When the job is restarted, the engine queries: "what is the highest `GlobalBatchSequence__c` where `IsCheckpoint__c = true`?" The answer is the resume point. All batches with a lower sequence number are skipped. The job picks up exactly where it left off.

Since each batch is a separate Queueable transaction, there is no partial batch state to unwind. Either a batch committed or it did not. The checkpoint only advances on full commitment.

### 5.5 Full Rollback in One Click

The rollback log is written as a side effect of the load, at the same time as the target records. There is no separate "enable rollback" step and no performance overhead of running rollback in addition to the load — the log insert is part of the same DML operation.

When rollback is triggered, the Batchable job reads the log and deletes records in reverse load order. Children are deleted before parents. A migration that loaded Account (order 1), Contact (order 2), and Opportunity (order 3) is rolled back as: Opportunities deleted first, then Contacts, then Accounts. Referential integrity is maintained throughout.

The rollback does not require knowing which specific records were inserted. The log knows. The client never needs to run a SOQL query, export IDs, or manually track down migrated records.

### 5.6 Real-Time Progress Dashboard

The LWC dashboard surfaces six metrics live, without polling a background process:

| Metric | Source |
|---|---|
| Records loaded | `SUM(MigrationBatch__c.SuccessCount__c)` |
| Records failed | `SUM(MigrationBatch__c.FailureCount__c)` |
| Records skipped | `MigrationJob__c.SkippedCount__c` |
| Percentage complete | `MigrationJob__c.PercentComplete__c` |
| Estimated time remaining | Derived from `EstimatedCompletionAt__c - NOW()` |
| Current object being loaded | `MigrationObjectConfig__c` where `Status__c = 'InProgress'` |

The client can see exactly what is happening without asking anyone. The dashboard refreshes on a short polling interval and updates within seconds of each batch completion.

### 5.7 Dry-Run Mode

Dry-run mode is the framework's most client-facing feature. It runs the complete validation pipeline — schema checks, required field checks, picklist validation, duplicate detection, relationship resolution — and produces a complete error report, all with zero DML committed to the target org.

The report the client receives from a dry run includes, for every error:

- The row number in the source file
- The Salesforce field API name and label
- The offending value
- The error type (e.g. "InvalidPicklistValue", "FieldTooLong", "RequiredFieldMissing")
- A suggested fix (e.g. "Allowed values: New, Working, Closed — received: Open")

This report is the conversation-starter for source data cleanup. The client fixes their data, runs dry-run again, and repeats until the report is empty. Then the live load runs with the guarantee that it will succeed.

---

## 6. Data Model Summary

The framework uses eight custom objects and two Custom Metadata Types. Full field-level specifications are in `docs/data_model.md`.

```
MigrationJob__c                    ← one record per migration run
 │
 ├── MigrationObjectConfig__c      ← one per object type (Account, Contact, etc.)
 │    ├── MigrationFieldMapping__c ← source→target column mappings
 │    ├── MigrationObjectDependency__c ← dependency graph edges
 │    └── MigrationBatch__c        ← one per 200-row chunk
 │         └── MigrationRowError__c ← one per row-level error
 │
 ├── MigrationRecordLog__c         ← every inserted SF ID (rollback log + ID map)
 └── MigrationRollback__c          ← rollback execution tracking
```

**Custom Metadata Types:**
- `MigrationFrameworkConfig__mdt` — org-wide defaults: batch size, retry limits, Platform Cache settings
- `MigrationObjectRule__mdt` — pre-seeded known object ordering rules (Account→Contact, Pricebook2→PricebookEntry, etc.)

**Key design decision — `MigrationRecordLog__c` serves two purposes.** The same record that powers rollback (delete all `Active` records in reverse `LoadOrder__c`) also powers ID resolution (look up `SalesforceId__c` by `LegacyId__c` + `ObjectApiName__c`). Keeping these in one object halves storage, reduces SOQL query count, and eliminates the consistency risk of two objects that must stay in sync.

---

## 7. Technical Implementation

### 7.1 Execution Model

The framework runs on two Apex patterns:

**Queueable chains** drive the main load. Each `MigrationBatch__c` record is processed by a dedicated Queueable job. When a job completes, it enqueues the next one. Queueable chains support up to 50 chained jobs per transaction, so the framework re-anchors the chain every 50 batches using a short-lived Schedulable that fires a new chain.

**Batchable Apex** handles the pre-validation pass and the rollback operation. These are read-heavy (validation) or delete-heavy (rollback) operations on large datasets where Batchable's built-in chunking is the right fit.

### 7.2 Platform Cache Strategy

Parent ID maps are the primary performance bottleneck for large migrations. A 100k-record parent object produces a `Map<String, Id>` that is ~27MB in Apex heap — exceeding the 12MB async transaction limit. Platform Cache eliminates this problem.

After each parent object batch commits, the engine serialises the cumulative ID map for that object type as JSON and writes it to Platform Cache, keyed by `{jobId}_{objectApiName}`. Child batches read from cache first. On a cache miss (TTL expired, cache evicted), the engine falls back to a bulk SOQL query and re-warms the cache.

If Platform Cache is not provisioned in the org (`EnablePlatformCache__c = false` in `MigrationFrameworkConfig__mdt`), the framework falls back to chunked SOQL with OFFSET paging — slower, but governor-limit safe.

### 7.3 Schema Validation in Apex

The validation engine uses `Schema.describeSObjects()` to retrieve field metadata. Results are cached in a static Map for the duration of the validation transaction — one Describe call per object type, not per row or per field.

The engine checks, in order:

1. Does the target field exist on the object? (unmapped source columns are flagged, not silently ignored)
2. Is the value null? If `IsRequired__c = true` and `DefaultValue__c` is blank, raise `RequiredFieldMissing`.
3. Is the value the correct type? Attempt type coercion. If it fails, raise `InvalidFieldType` with the attempted conversion.
4. Does the value fit? For Text, check length against `Schema.DescribeFieldResult.getLength()`. Raise `FieldTooLong` with the limit and the actual length.
5. Is the value an allowed picklist value? For Picklist and MultiPicklist fields, compare against `Schema.DescribeFieldResult.getPicklistValues()`. Raise `InvalidPicklistValue` with the full allowed-values list.

### 7.4 Relationship Resolution in Apex

```
For each row in the current batch:
    For each field where IsParentLookup__c = true:
        1. Read legacyParentId from source row
        2. Look up Platform Cache key: {jobId}_{parentObjectName}
        3. If hit: replace with SalesforceId from cache
        4. If miss: query MigrationRecordLog__c, rebuild cache, then resolve
        5. If not found: raise ParentRecordNotFound error (row is excluded from DML)
```

The `ParentRecordNotFound` error is a hard exclusion. A child record that cannot resolve its parent would cause a Salesforce foreign key violation at the DML layer. The framework catches this before DML and logs the row error with the unresolvable legacy ID, allowing the rest of the batch to proceed.

### 7.5 LWC Dashboard Architecture

The dashboard LWC subscribes to a Platform Event (`MigrationProgressEvent__e`) published after each batch completion. This eliminates polling: the UI updates within 1–2 seconds of each batch commit, driven by the event bus rather than a timer.

The Platform Event payload contains:
- `JobId__c`
- `LoadedCount__c`, `FailedCount__c`, `PercentComplete__c`
- `CurrentObjectName__c`
- `EstimatedCompletionAt__c`

The LWC also queries `MigrationRowError__c` on demand (triggered by clicking a "View Errors" action) to show the paginated error report without loading the full dataset on initial render.

### 7.6 Self-Referential Two-Pass Strategy

For objects with self-referential lookups:

**Pass 1** — Insert all records with the self-reference field set to null. Every record gets a Salesforce ID. Every ID is written to `MigrationRecordLog__c`. A `MigrationBatch__c` with `IsSecondPass__c = false` marks this phase.

**Pass 2** — Run an update-only batch over the same records. For each record, resolve the self-reference field value from `MigrationRecordLog__c` (legacy self-reference ID → Salesforce ID). Call `Database.update()` with `allOrNone = false`. A `MigrationBatch__c` with `IsSecondPass__c = true` marks this phase.

Only records where the source data includes a self-reference value are updated in pass 2. Records with a null self-reference field are not touched.

---

## 8. Non-Functional Characteristics

### Performance

| Dataset size | Batches (200 rows each) | Estimated load time |
|---|---|---|
| 10,000 records | 50 | ~5 minutes |
| 50,000 records | 250 | ~25 minutes |
| 100,000 records | 500 | ~50 minutes |
| 500,000 records | 2,500 | ~4 hours |

Estimates assume average trigger overhead (~1 second per batch). Heavier trigger chains on the target object will increase per-batch time. The framework itself adds less than 200ms per batch overhead beyond raw DML time.

### Governor Limit Profile (per batch transaction)

| Limit | Budget | Framework usage |
|---|---|---|
| DML rows | 10,000 | ~400 (200 target + 200 log records) |
| SOQL queries | 200 (async) | ~6–10 |
| Heap | 12MB (async) | <2MB (with Platform Cache) |
| CPU time | 60,000ms (async) | ~500ms framework + trigger overhead |
| Queueable jobs enqueued | 50 | 1 per batch |

### Scalability Constraints

- **Maximum practical batch dataset:** ~1 million records per object. Beyond this, Platform Cache TTL (1 hour) may expire during very long-running jobs. The fallback to SOQL still works but is slower.
- **Maximum objects per job:** No hard limit. Topological sort is O(V + E) and completes in well under 1 second for up to 100 objects.
- **Storage:** `MigrationRecordLog__c` is the dominant consumer. A 1-million-record migration generates approximately 1 million log records (~1GB of data storage). Post-migration cleanup via the scheduled purge job is essential.

### Reliability

- Every batch is idempotent in `Upsert` mode — re-running a completed batch does not create duplicates.
- The checkpoint system guarantees at-most-once DML per record per job (in `Insert` mode, duplicate inserts are caught by the external ID uniqueness check and raised as errors before DML).
- The rollback log captures `Action__c` (Inserted vs Updated) so rollback can target only inserted records and avoid deleting records that existed before the migration.

---

## 9. Deployment and Configuration

### 9.1 Package Contents

```
force-app/main/default/
  objects/
    MigrationJob__c/
    MigrationObjectConfig__c/
    MigrationObjectDependency__c/
    MigrationFieldMapping__c/
    MigrationBatch__c/
    MigrationRowError__c/
    MigrationRecordLog__c/
    MigrationRollback__c/
  customMetadata/
    MigrationFrameworkConfig__mdt/
    MigrationObjectRule__mdt/
  classes/
    MigrationJobService.cls          ← job creation and configuration API
    MigrationValidationEngine.cls    ← schema validation logic
    MigrationRelationshipResolver.cls ← dependency graph + topological sort
    MigrationBatchExecutor.cls       ← Queueable batch processor
    MigrationBatchableExecutor.cls   ← Batchable for validation and rollback
    MigrationRollbackService.cls     ← rollback log management
    MigrationIdCache.cls             ← Platform Cache abstraction
    MigrationProgressPublisher.cls   ← Platform Event publisher
  lwc/
    migrationDashboard/              ← progress + error dashboard
    migrationJobConfig/              ← job setup UI
  platformEventChannels/
    MigrationProgressEvent__e.channel-meta.xml
```

### 9.2 Setup Steps

1. Deploy the package to the target org using `sf project deploy start`.
2. Configure `MigrationFrameworkConfig__mdt` with the correct Platform Cache partition name (or set `EnablePlatformCache__c = false` if Platform Cache is not available).
3. Add the `migrationDashboard` LWC to a Lightning App page or utility bar.
4. Assign the `Migration_Manager` permission set to users who will run migrations.
5. Assign the `Migration_Viewer` permission set to users who only need dashboard access.

### 9.3 Creating a Migration Job

A migration is set up through the `MigrationJobService` Apex class or through the `migrationJobConfig` LWC:

1. Create a `MigrationJob__c` record: set `Mode__c`, `SourceType__c`, `IsDryRun__c`.
2. Create a `MigrationObjectConfig__c` for each object: set `ObjectApiName__c`, `ExternalIdField__c`.
3. Create `MigrationFieldMapping__c` records for each source column: set `SourceFieldName__c`, `TargetFieldApiName__c`, `TransformationType__c`.
4. Call `MigrationRelationshipResolver.resolveForJob(jobId)` — this populates `LoadOrder__c` and creates `MigrationObjectDependency__c` edges automatically.
5. Set `MigrationJob__c.Status__c = 'Validating'` to trigger the validation pass.
6. Review the validation report (dry-run) or proceed to load (`Status__c = 'Running'`).

---

## 10. What This Framework Achieves

### For the migration engineer

- **No manual dependency management.** Stop maintaining a spreadsheet of "load Account before Contact before Opportunity." The resolver reads the org's own metadata and figures it out.
- **No re-runs from scratch.** A failure at batch 499 of 500 is a five-minute fix, not a three-hour re-run. The checkpoint system means failures are recovery events, not catastrophes.
- **Clear error attribution.** When something fails, the `MigrationRowError__c` record tells you the row number, the field, the value, and why. No more parsing cryptic Salesforce error logs.

### For the client

- **Data quality visibility before cutover.** Dry-run mode turns the first migration attempt from a live experiment into a structured analysis. The client sees what their data looks like against their actual org configuration, with actionable fixes for every problem.
- **Live progress during the migration window.** The dashboard answers "how is it going?" with numbers, not estimates. Clients can see exactly which object is loading, how many records are through, and when it will finish.
- **A genuine undo button.** One-click rollback removes every migrated record in the correct order. If the post-migration review finds a problem, recovery is minutes — not a support ticket.

### For the project

- **Shorter migration windows.** Partial success means a 200-record batch with three bad rows does not become a 200-record failure. The throughput of a migration is determined by the data, not by the error rate.
- **Predictable outcomes.** Zero-DML dry-run means the first live load attempt is not a discovery exercise. The errors have already been found and fixed. The live load does what the dry run said it would.
- **Auditability.** Every record loaded, every error encountered, every batch timing, and every rollback action is stored in Salesforce custom objects with full audit trail. Post-migration sign-off is a reporting exercise, not a manual reconciliation.

### The core promise

A migration run with this framework ends in one of exactly three states:
1. **Complete:** every row that could be loaded was loaded. Every row that could not be loaded has a named error with a suggested fix.
2. **Paused/failed with checkpoint:** the job can resume from where it stopped. No data was lost. No work was duplicated.
3. **Rolled back:** every record inserted by this job has been deleted. The target org is in exactly the state it was in before the job started.

There is no fourth state. There is no "partially migrated with unknown records scattered across the org." The framework makes the fourth state structurally impossible.
