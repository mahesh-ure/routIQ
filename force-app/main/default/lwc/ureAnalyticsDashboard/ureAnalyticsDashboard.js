import { LightningElement, wire, track } from 'lwc';
import getDefaultLookbackDays from '@salesforce/apex/RoutingAnalyticsService.getDefaultLookbackDays';
import getRoutingVelocity from '@salesforce/apex/RoutingAnalyticsService.getRoutingVelocity';
import getSlaCompliance from '@salesforce/apex/RoutingAnalyticsService.getSlaCompliance';
import getAgentUtilisation from '@salesforce/apex/RoutingAnalyticsService.getAgentUtilisation';
import { refreshApex } from '@salesforce/apex';

// Custom Labels (i18n)
import TITLE from '@salesforce/label/c.URE_AnalyticsDashboardTitle';
import VELOCITY_TITLE from '@salesforce/label/c.URE_VelocityTitle';
import VELOCITY_SUBTITLE from '@salesforce/label/c.URE_VelocitySubtitle';
import SLA_TITLE from '@salesforce/label/c.URE_SlaComplianceTitle';
import SLA_SUBTITLE from '@salesforce/label/c.URE_SlaComplianceSubtitle';
import UTIL_TITLE from '@salesforce/label/c.URE_AgentUtilisationTitle';
import UTIL_SUBTITLE from '@salesforce/label/c.URE_AgentUtilisationSubtitle';
import NO_DATA from '@salesforce/label/c.URE_AnalyticsNoData';
import ERROR_MSG from '@salesforce/label/c.URE_AnalyticsError';
import BY_CONFIG from '@salesforce/label/c.URE_ByConfig';
import BY_AGENT from '@salesforce/label/c.URE_ByAgent';
import MET from '@salesforce/label/c.URE_Met';
import BREACHED from '@salesforce/label/c.URE_Breached';
import COMPLIANCE_RATE from '@salesforce/label/c.URE_ComplianceRate';
import AVG_DURATION from '@salesforce/label/c.URE_AvgDuration';
import ASSIGNMENTS from '@salesforce/label/c.URE_Assignments';
import REFRESH from '@salesforce/label/c.URE_AnalyticsRefresh';
import MS_UNIT from '@salesforce/label/c.URE_Milliseconds';

const SLA_COLUMNS = [
    { label: '', fieldName: 'groupName', type: 'text', initialWidth: 200 },
    { label: '', fieldName: 'metCount', type: 'number', initialWidth: 80, cellAttributes: { class: 'slds-text-color_success' } },
    { label: '', fieldName: 'breachedCount', type: 'number', initialWidth: 100, cellAttributes: { class: 'slds-text-color_error' } },
    { label: '', fieldName: 'complianceRate', type: 'percent', initialWidth: 140,
        typeAttributes: { minimumFractionDigits: 1, maximumFractionDigits: 1 }
    }
];

export default class UreAnalyticsDashboard extends LightningElement {
    label = {
        TITLE, VELOCITY_TITLE, VELOCITY_SUBTITLE,
        SLA_TITLE, SLA_SUBTITLE, UTIL_TITLE, UTIL_SUBTITLE,
        NO_DATA, ERROR_MSG, BY_CONFIG, BY_AGENT,
        MET, BREACHED, COMPLIANCE_RATE, AVG_DURATION,
        ASSIGNMENTS, REFRESH, MS_UNIT
    };

    // ─── Lookback days from Analytics_Settings__c (Custom Setting) ───
    // Reactive property — when set by the config wire, triggers the
    // dependent lens wire adapters automatically.
    @track lookbackDays;
    _configWire;

    // ─── Velocity ────────────────────────────────────────────────────
    velocityData = [];
    velocityError;
    _velocityWire;

    // ─── SLA ─────────────────────────────────────────────────────────
    slaByConfig = [];
    slaByAgent = [];
    slaError;
    @track activeSlaTab = 'config';
    _slaWire;

    // ─── Utilisation ─────────────────────────────────────────────────
    utilisationData = [];
    utilisationError;
    _utilisationWire;

    isRefreshing = false;

    // ─── Config wire — loads lookback days from Custom Setting ───────
    // Fires first. When lookbackDays becomes non-null, the dependent
    // lens wires ($lookbackDays) fire automatically via reactivity.
    @wire(getDefaultLookbackDays)
    wiredConfig(result) {
        this._configWire = result;
        if (result.data !== undefined) {
            this.lookbackDays = result.data;
        } else if (result.error) {
            // Fallback if Custom Setting query fails — should never happen
            // since getInstance() is zero-SOQL, but defensive coding.
            this.lookbackDays = 30;
        }
    }

    // ─── SLA data table columns (set labels from custom labels) ─────
    get slaColumns() {
        return [
            { ...SLA_COLUMNS[0], label: this.activeSlaTab === 'config' ? this.label.BY_CONFIG : this.label.BY_AGENT },
            { ...SLA_COLUMNS[1], label: this.label.MET },
            { ...SLA_COLUMNS[2], label: this.label.BREACHED },
            { ...SLA_COLUMNS[3], label: this.label.COMPLIANCE_RATE }
        ];
    }

    get activeSlaData() {
        return this.activeSlaTab === 'config' ? this.slaByConfig : this.slaByAgent;
    }

    get isConfigTab() {
        return this.activeSlaTab === 'config';
    }

    get isAgentTab() {
        return this.activeSlaTab === 'agent';
    }

    get configTabClass() {
        return this.activeSlaTab === 'config' ? 'tab-btn-active' : 'tab-btn';
    }

    get agentTabClass() {
        return this.activeSlaTab === 'agent' ? 'tab-btn-active' : 'tab-btn';
    }

    // ─── Computed getters ────────────────────────────────────────────
    get hasVelocityData() {
        return this.velocityData && this.velocityData.length > 0;
    }

    get hasSlaData() {
        return this.activeSlaData && this.activeSlaData.length > 0;
    }

    get hasUtilisationData() {
        return this.utilisationData && this.utilisationData.length > 0;
    }

    get overallAvgDuration() {
        if (!this.hasVelocityData) return '\u2014';
        const total = this.velocityData.reduce((sum, dp) => sum + (dp.avgDurationMs || 0) * (dp.routingCount || 1), 0);
        const count = this.velocityData.reduce((sum, dp) => sum + (dp.routingCount || 0), 0);
        return count > 0 ? Math.round(total / count) : 0;
    }

    get totalRoutings() {
        if (!this.hasVelocityData) return 0;
        return this.velocityData.reduce((sum, dp) => sum + (dp.routingCount || 0), 0);
    }

    get overallComplianceRate() {
        const data = this.activeSlaData;
        if (!data || data.length === 0) return '\u2014';
        const totalMet = data.reduce((sum, r) => sum + (r.metCount || 0), 0);
        const totalBreached = data.reduce((sum, r) => sum + (r.breachedCount || 0), 0);
        const total = totalMet + totalBreached;
        return total > 0 ? (totalMet / total * 100).toFixed(1) : '0.0';
    }

    // ─── Utilisation: transform to per-agent summary ─────────────────
    get utilisationSummary() {
        if (!this.utilisationData || this.utilisationData.length === 0) return [];
        const agentMap = {};
        for (const dp of this.utilisationData) {
            if (!agentMap[dp.agentName]) {
                agentMap[dp.agentName] = { totalAssigned: 0, daysActive: 0 };
            }
            agentMap[dp.agentName].totalAssigned += dp.assignedCount || 0;
            agentMap[dp.agentName].daysActive += 1;
        }
        return Object.entries(agentMap).map(([name, stats]) => ({
            agentName: name,
            totalAssigned: stats.totalAssigned,
            daysActive: stats.daysActive,
            avgPerDay: stats.daysActive > 0
                ? (stats.totalAssigned / stats.daysActive).toFixed(1)
                : '0.0',
            id: name
        }));
    }

    get hasUtilisationSummary() {
        return this.utilisationSummary && this.utilisationSummary.length > 0;
    }

    // ─── Dependent wire adapters ─────────────────────────────────────
    // $lookbackDays is reactive — wires fire ONLY after config wire
    // populates lookbackDays. Null lookbackDays = wires don't fire.

    @wire(getRoutingVelocity, { days: '$lookbackDays' })
    wiredVelocity(result) {
        this._velocityWire = result;
        if (result.data) {
            this.velocityData = result.data;
            this.velocityError = undefined;
        } else if (result.error) {
            this.velocityError = result.error;
            this.velocityData = [];
        }
    }

    @wire(getSlaCompliance, { days: '$lookbackDays' })
    wiredSla(result) {
        this._slaWire = result;
        if (result.data) {
            this.slaByConfig = this._transformSlaForTable(result.data.byConfig);
            this.slaByAgent = this._transformSlaForTable(result.data.byAgent);
            this.slaError = undefined;
        } else if (result.error) {
            this.slaError = result.error;
            this.slaByConfig = [];
            this.slaByAgent = [];
        }
    }

    @wire(getAgentUtilisation, { days: '$lookbackDays' })
    wiredUtilisation(result) {
        this._utilisationWire = result;
        if (result.data) {
            this.utilisationData = result.data;
            this.utilisationError = undefined;
        } else if (result.error) {
            this.utilisationError = result.error;
            this.utilisationData = [];
        }
    }

    // ─── Event handlers ──────────────────────────────────────────────
    handleSlaTabSwitch(event) {
        this.activeSlaTab = event.target.dataset.tab;
    }

    async handleRefresh() {
        this.isRefreshing = true;
        try {
            await Promise.all([
                refreshApex(this._configWire),
                refreshApex(this._velocityWire),
                refreshApex(this._slaWire),
                refreshApex(this._utilisationWire)
            ]);
        } finally {
            this.isRefreshing = false;
        }
    }

    // ─── Private helpers ─────────────────────────────────────────────
    _transformSlaForTable(slaList) {
        if (!slaList) return [];
        return slaList.map((item) => ({
            ...item,
            complianceRate: item.complianceRate / 100,
            id: item.groupName
        }));
    }
}
