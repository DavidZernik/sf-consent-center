import { LightningElement, api } from 'lwc';

const BAND_CLASS = {
    'Highly engaged': 'score-ring score-ring_high',
    Engaged: 'score-ring score-ring_medium',
    'At risk': 'score-ring score-ring_low',
    Dormant: 'score-ring score-ring_dormant',
    'No data': 'score-ring score-ring_dormant'
};

/**
 * Engagement Calculated Insight, rendered as a score ring plus its inputs.
 *
 * A Calculated Insight is precomputed in Data Cloud rather than aggregated at read time, which
 * is the whole reason it is fast enough to sit on a record page. Showing the contributing
 * counts next to the score keeps it from looking like an unexplained number.
 */
export default class EngagementInsightTile extends LightningElement {
    _engagement;

    @api
    get engagement() {
        return this._engagement;
    }
    set engagement(value) {
        this._engagement = value ?? undefined;
    }

    get hasData() {
        return Boolean(this._engagement) && this._engagement.band !== 'No data';
    }

    get scoreLabel() {
        const score = this._engagement?.score;
        return score === null || score === undefined ? '-' : Math.round(score);
    }

    get band() {
        return this._engagement?.band ?? 'No data';
    }

    get ringClass() {
        return BAND_CLASS[this.band] ?? BAND_CLASS['No data'];
    }

    /** Conic-gradient sweep for the ring, so the score reads at a glance. */
    get ringStyle() {
        const score = Math.max(0, Math.min(100, Number(this._engagement?.score ?? 0)));
        return `--score-angle: ${score * 3.6}deg;`;
    }

    get metrics() {
        return [
            { key: 'opens', label: 'Email opens (90d)', value: this._engagement?.emailOpens90d ?? 0 },
            { key: 'clicks', label: 'Clicks (90d)', value: this._engagement?.clicks90d ?? 0 }
        ];
    }

    get lastEngagementAt() {
        return this._engagement?.lastEngagementAt;
    }
}
