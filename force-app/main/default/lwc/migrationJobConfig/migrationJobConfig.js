import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import createJob        from '@salesforce/apex/MigrationDashboardController.createJob';
import addObjectConfig  from '@salesforce/apex/MigrationDashboardController.addObjectConfig';
import addFieldMapping  from '@salesforce/apex/MigrationDashboardController.addFieldMapping';
import startJob         from '@salesforce/apex/MigrationDashboardController.startJob';

const STEPS = ['Job', 'Objects', 'Fields', 'Review'];

export default class MigrationJobConfig extends LightningElement {

    @track currentStep   = 0;
    @track jobId         = null;
    @track jobName       = '';
    @track isDryRun      = false;
    @track isLoading     = false;

    // Object config state
    @track objectRows = [{ id: 0, apiName: '', externalIdField: '', loadOrder: 1 }];
    _objectCounter = 1;
    @track configIdMap = {};   // apiName → configId after step 2 save

    // Field mapping state
    @track fieldRows = [{ id: 0, configApiName: '', source: '', target: '', isLookup: false, parentObj: '' }];
    _fieldCounter = 1;

    // ── Step navigation ───────────────────────────────────────────────────────

    get stepLabel()    { return STEPS[this.currentStep]; }
    get isStep0()      { return this.currentStep === 0; }
    get isStep1()      { return this.currentStep === 1; }
    get isStep2()      { return this.currentStep === 2; }
    get isStep3()      { return this.currentStep === 3; }
    get isLastStep()   { return this.currentStep === STEPS.length - 1; }
    get isFirstStep()  { return this.currentStep === 0; }

    get currentStepValue() { return String(this.currentStep); }

    get launchLabel() {
        return this.isDryRun ? 'Start Dry Run' : 'Launch Migration';
    }

    // ── Step 0 — Job details ──────────────────────────────────────────────────

    handleJobName(evt)   { this.jobName  = evt.target.value; }
    handleDryRun(evt)    { this.isDryRun = evt.target.checked; }

    handleNextFromJob() {
        if (!this.jobName.trim()) {
            this._toast('Job name is required', '', 'error');
            return;
        }
        this.isLoading = true;
        createJob({ jobName: this.jobName, isDryRun: this.isDryRun })
            .then(id => {
                this.jobId = id;
                this.currentStep = 1;
            })
            .catch(err => this._toast('Create failed', err.body?.message, 'error'))
            .finally(() => { this.isLoading = false; });
    }

    // ── Step 1 — Object configs ───────────────────────────────────────────────

    handleAddObject() {
        this.objectRows = [...this.objectRows,
            { id: this._objectCounter++, apiName: '', externalIdField: '', loadOrder: this.objectRows.length + 1 }];
    }

    handleRemoveObject(evt) {
        const id = Number(evt.target.dataset.rowid);
        this.objectRows = this.objectRows.filter(r => r.id !== id);
    }

    handleObjectField(evt) {
        const { rowid, field } = evt.target.dataset;
        this.objectRows = this.objectRows.map(r =>
            r.id === Number(rowid) ? { ...r, [field]: evt.target.value } : r);
    }

    handleNextFromObjects() {
        const invalid = this.objectRows.filter(r => !r.apiName.trim());
        if (invalid.length) {
            this._toast('All objects need an API name', '', 'error');
            return;
        }
        this.isLoading = true;
        const saves = this.objectRows.map(r =>
            addObjectConfig({
                jobId: this.jobId,
                targetObjectApiName: r.apiName,
                loadOrder: r.loadOrder,
                externalIdField: r.externalIdField || null,
            }).then(configId => ({ apiName: r.apiName, configId }))
        );
        Promise.all(saves)
            .then(results => {
                results.forEach(({ apiName, configId }) => {
                    this.configIdMap = { ...this.configIdMap, [apiName]: configId };
                });
                this.currentStep = 2;
            })
            .catch(err => this._toast('Object config failed', err.body?.message, 'error'))
            .finally(() => { this.isLoading = false; });
    }

    // ── Step 2 — Field mappings ───────────────────────────────────────────────

    get objectOptions() {
        return this.objectRows.map(r => ({ label: r.apiName, value: r.apiName }));
    }

    handleAddField() {
        this.fieldRows = [...this.fieldRows,
            { id: this._fieldCounter++, configApiName: '', source: '', target: '', isLookup: false, parentObj: '' }];
    }

    handleRemoveField(evt) {
        const id = Number(evt.target.dataset.rowid);
        this.fieldRows = this.fieldRows.filter(r => r.id !== id);
    }

    handleFieldChange(evt) {
        const { rowid, field } = evt.target.dataset;
        const value = evt.target.type === 'checkbox' ? evt.target.checked : evt.target.value;
        this.fieldRows = this.fieldRows.map(r =>
            r.id === Number(rowid) ? { ...r, [field]: value } : r);
    }

    handleNextFromFields() {
        this.isLoading = true;
        const saves = this.fieldRows
            .filter(r => r.source.trim() && r.target.trim() && r.configApiName)
            .map(r =>
                addFieldMapping({
                    configId: this.configIdMap[r.configApiName],
                    sourceFieldName: r.source,
                    targetFieldApiName: r.target,
                    isRelationship: r.isLookup,
                    relatedObjectApiName: r.isLookup ? r.parentObj : null,
                })
            );
        Promise.all(saves)
            .then(() => { this.currentStep = 3; })
            .catch(err => this._toast('Field mapping failed', err.body?.message, 'error'))
            .finally(() => { this.isLoading = false; });
    }

    // ── Step 3 — Review & launch ──────────────────────────────────────────────

    get reviewSummary() {
        return {
            jobName  : this.jobName,
            isDryRun : this.isDryRun,
            objects  : this.objectRows.length,
            fields   : this.fieldRows.filter(r => r.source.trim()).length,
        };
    }

    handleLaunch() {
        this.isLoading = true;
        startJob({ jobId: this.jobId })
            .then(() => {
                this._toast('Migration started',
                    `Job "${this.jobName}" is now ${this.isDryRun ? 'validating (dry run)' : 'loading data'}.`,
                    'success');
                this.dispatchEvent(new CustomEvent('jobstarted', { detail: { jobId: this.jobId } }));
                this._reset();
            })
            .catch(err => this._toast('Start failed', err.body?.message, 'error'))
            .finally(() => { this.isLoading = false; });
    }

    handleBack() {
        if (this.currentStep > 0) this.currentStep--;
    }

    // ── Utilities ─────────────────────────────────────────────────────────────

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message: message || '', variant }));
    }

    _reset() {
        this.currentStep  = 0;
        this.jobId        = null;
        this.jobName      = '';
        this.isDryRun     = false;
        this.objectRows   = [{ id: 0, apiName: '', externalIdField: '', loadOrder: 1 }];
        this.fieldRows    = [{ id: 0, configApiName: '', source: '', target: '', isLookup: false, parentObj: '' }];
        this.configIdMap  = {};
        this._objectCounter = 1;
        this._fieldCounter  = 1;
    }
}
