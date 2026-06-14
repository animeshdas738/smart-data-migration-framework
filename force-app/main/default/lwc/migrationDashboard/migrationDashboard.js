import { LightningElement, track, wire } from 'lwc';
import { subscribe, unsubscribe, onError, setDebugFlag, isEmpEnabled } from 'lightning/empApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getActiveJobs from '@salesforce/apex/MigrationDashboardController.getActiveJobs';
import cancelJob    from '@salesforce/apex/MigrationDashboardController.cancelJob';
import startRollback from '@salesforce/apex/MigrationDashboardController.startRollback';

const CHANNEL = '/event/MigrationProgressEvent__e';

export default class MigrationDashboard extends LightningElement {
    @track jobs = [];
    @track error;

    _subscription = null;
    _pollInterval  = null;

    // ── Lifecycle ────────────────────────────────────────────────────────────

    connectedCallback() {
        this._loadJobs();
        this._subscribe();
        // Fallback poll every 30 s in case empApi is unavailable
        this._pollInterval = setInterval(() => this._loadJobs(), 30000);
    }

    disconnectedCallback() {
        this._unsubscribe();
        clearInterval(this._pollInterval);
    }

    // ── Data loading ─────────────────────────────────────────────────────────

    _loadJobs() {
        getActiveJobs()
            .then(data => { this.jobs = data.map(j => this._enrich(j)); this.error = null; })
            .catch(err => { this.error = err.body?.message || 'Failed to load jobs'; });
    }

    _enrich(job) {
        return {
            ...job,
            progressStyle   : `width: ${Math.min(job.PercentComplete__c || 0, 100)}%`,
            progressLabel   : `${(job.PercentComplete__c || 0).toFixed(1)}%`,
            isRunning       : job.Status__c === 'InProgress' || job.Status__c === 'Validating',
            isCompleted     : job.Status__c === 'Completed' || job.Status__c === 'DryRunPassed',
            isFailed        : job.Status__c === 'Failed' || job.Status__c === 'ValidationFailed',
            canCancel       : job.Status__c === 'InProgress' || job.Status__c === 'Validating',
            canRollback     : job.Status__c === 'Completed',
            statusClass     : this._statusClass(job.Status__c),
        };
    }

    _statusClass(status) {
        const map = {
            InProgress: 'slds-badge slds-badge_lightest status-running',
            Validating: 'slds-badge slds-badge_lightest status-running',
            Completed:  'slds-badge slds-theme_success',
            DryRunPassed: 'slds-badge slds-theme_success',
            Failed:     'slds-badge slds-theme_error',
            ValidationFailed: 'slds-badge slds-theme_error',
            Cancelled:  'slds-badge',
            RolledBack: 'slds-badge',
        };
        return map[status] || 'slds-badge';
    }

    // ── Platform Event subscription ───────────────────────────────────────────

    _subscribe() {
        isEmpEnabled()
            .then(enabled => {
                if (!enabled) return;
                onError(err => console.error('EMP error', err));
                subscribe(CHANNEL, -1, this._handleEvent.bind(this))
                    .then(sub => { this._subscription = sub; });
            });
    }

    _unsubscribe() {
        if (this._subscription) {
            unsubscribe(this._subscription);
            this._subscription = null;
        }
    }

    _handleEvent({ data }) {
        const payload = data.payload;
        const jobId   = payload.JobId__c;
        this.jobs = this.jobs.map(j => {
            if (j.Id !== jobId) return j;
            return this._enrich({
                ...j,
                LoadedCount__c      : payload.LoadedCount__c,
                FailedCount__c      : payload.FailedCount__c,
                PercentComplete__c  : payload.PercentComplete__c,
                CurrentObject__c    : payload.CurrentObjectName__c,
                EstimatedCompletionAt__c: payload.EstimatedCompletionAt__c,
                Status__c           : 'InProgress',
            });
        });
    }

    // ── Actions ──────────────────────────────────────────────────────────────

    handleCancel(evt) {
        const jobId = evt.target.dataset.jobid;
        cancelJob({ jobId })
            .then(() => {
                this._toast('Job cancelled', '', 'success');
                this._loadJobs();
            })
            .catch(err => this._toast('Cancel failed', err.body?.message, 'error'));
    }

    handleRollback(evt) {
        const jobId = evt.target.dataset.jobid;
        startRollback({ jobId })
            .then(() => {
                this._toast('Rollback started', 'Records will be deleted in reverse load order.', 'info');
                this._loadJobs();
            })
            .catch(err => this._toast('Rollback failed', err.body?.message, 'error'));
    }

    handleRefresh() {
        this._loadJobs();
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    get hasJobs() { return this.jobs.length > 0; }
    get hasError() { return !!this.error; }
}
