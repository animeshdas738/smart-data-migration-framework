/**
 * Builds the topological load order for all objects in a migration job.
 *
 * Algorithm:
 *   1. Load MigrationObjectDependency__c edges for the job's object set.
 *   2. Apply any MigrationObjectRule__mdt overrides (bootstrap well-known hierarchies).
 *   3. Run Kahn's topological sort. On cycle detection, flag self-referential objects
 *      for two-pass loading (pass 1: insert with null self-ref; pass 2: update).
 *   4. Write the resolved LoadOrder__c back to each MigrationObjectConfig__c.
 */
public with sharing class MigrationRelationshipResolver {

    public class ResolutionResult {
        public List<String> orderedApiNames  = new List<String>();     // parent-first
        public Set<String>  selfReferential  = new Set<String>();      // two-pass needed
        public Boolean      success          = true;
        public String       errorMessage;
    }

    // ─── Public API ──────────────────────────────────────────────────────────

    public ResolutionResult resolve(Id jobId) {
        // Load all object configs for this job
        List<MigrationObjectConfig__c> configs = [
            SELECT Id, ObjectApiName__c, LoadOrder__c
            FROM MigrationObjectConfig__c
            WHERE MigrationJob__c = :jobId
              AND IsActive__c = true
            ORDER BY LoadOrder__c NULLS LAST
        ];

        if (configs.isEmpty()) {
            ResolutionResult r = new ResolutionResult();
            r.success = false;
            r.errorMessage = 'No active MigrationObjectConfig records found for job ' + jobId;
            return r;
        }

        Map<String, Id> apiNameToConfigId = new Map<String, Id>();
        Set<String> objectSet = new Set<String>();
        for (MigrationObjectConfig__c c : configs) {
            apiNameToConfigId.put(c.ObjectApiName__c, c.Id);
            objectSet.add(c.ObjectApiName__c);
        }

        // ── Build adjacency list (parent → children) and in-degree map ──────
        Map<String, Set<String>> children  = new Map<String, Set<String>>();
        Map<String, Integer>     inDegree  = new Map<String, Integer>();
        for (String obj : objectSet) {
            children.put(obj, new Set<String>());
            inDegree.put(obj, 0);
        }

        // Explicit dependency edges from the job's config
        List<MigrationObjectDependency__c> deps = [
            SELECT ParentObjectConfig__r.ObjectApiName__c,
                   ChildObjectConfig__r.ObjectApiName__c
            FROM MigrationObjectDependency__c
            WHERE ParentObjectConfig__r.MigrationJob__c = :jobId
              AND ChildObjectConfig__r.MigrationJob__c  = :jobId
        ];

        Set<String> selfRefs = new Set<String>();
        for (MigrationObjectDependency__c d : deps) {
            String parent = d.ParentObjectConfig__r.ObjectApiName__c;
            String child  = d.ChildObjectConfig__r.ObjectApiName__c;
            if (parent == child) {
                selfRefs.add(parent);
                continue; // self-loop → two-pass, skip from sort
            }
            if (!objectSet.contains(parent) || !objectSet.contains(child)) {
                continue;
            }
            children.get(parent).add(child);
            inDegree.put(child, inDegree.get(child) + 1);
        }

        // Bootstrap from MigrationObjectRule__mdt for well-known hierarchies
        applyKnownRules(objectSet, children, inDegree, selfRefs);

        // ── Kahn's topological sort ───────────────────────────────────────────
        List<String> queue   = new List<String>();
        List<String> ordered = new List<String>();
        for (String obj : objectSet) {
            if (inDegree.get(obj) == 0) {
                queue.add(obj);
            }
        }

        while (!queue.isEmpty()) {
            String current = queue.remove(0);
            ordered.add(current);
            for (String child : children.get(current)) {
                Integer newDeg = inDegree.get(child) - 1;
                inDegree.put(child, newDeg);
                if (newDeg == 0) {
                    queue.add(child);
                }
            }
        }

        // Any object still with in-degree > 0 after the sort has a real cycle
        // (not self-referential) — treat as unresolvable
        if (ordered.size() < objectSet.size()) {
            ResolutionResult r = new ResolutionResult();
            r.success = false;
            Set<String> cycle = new Set<String>(objectSet);
            cycle.removeAll(new Set<String>(ordered));
            r.errorMessage = 'Circular dependency detected between: ' + cycle;
            return r;
        }

        // ── Persist resolved order back to MigrationObjectConfig__c ──────────
        List<MigrationObjectConfig__c> toUpdate = new List<MigrationObjectConfig__c>();
        for (Integer i = 0; i < ordered.size(); i++) {
            toUpdate.add(new MigrationObjectConfig__c(
                Id = apiNameToConfigId.get(ordered[i]),
                LoadOrder__c = i + 1
            ));
        }
        update toUpdate;

        ResolutionResult result = new ResolutionResult();
        result.orderedApiNames = ordered;
        result.selfReferential = selfRefs;
        return result;
    }

    // ─── Known-rules bootstrap ───────────────────────────────────────────────

    private void applyKnownRules(
        Set<String> objectSet,
        Map<String, Set<String>> children,
        Map<String, Integer>     inDegree,
        Set<String>              selfRefs
    ) {
        List<MigrationObjectRule__mdt> rules = [
            SELECT ParentObjectApiName__c, ChildObjectApiName__c, IsAlwaysRequired__c
            FROM MigrationObjectRule__mdt
        ];

        for (MigrationObjectRule__mdt rule : rules) {
            String parent = rule.ParentObjectApiName__c;
            String child  = rule.ChildObjectApiName__c;
            Boolean bothInScope = objectSet.contains(parent) && objectSet.contains(child);
            if (!bothInScope && !rule.IsAlwaysRequired__c) {
                continue;
            }
            if (parent == child) {
                selfRefs.add(parent);
                continue;
            }
            if (!objectSet.contains(parent) || !objectSet.contains(child)) {
                continue;
            }
            if (!children.get(parent).contains(child)) {
                children.get(parent).add(child);
                inDegree.put(child, inDegree.get(child) + 1);
            }
        }
    }
}
