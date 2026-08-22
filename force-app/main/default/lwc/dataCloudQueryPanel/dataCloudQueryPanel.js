import { LightningElement, api } from 'lwc';

/**
 * Shows the Data Cloud queries behind the unified profile.
 *
 * "3 Data Cloud queries" is a number nobody can check. The statements, the DMO each one hits,
 * the rows returned and the time taken are checkable, and they are what an engineer reviewing
 * this actually wants to see.
 *
 * The query text arrives null unless the running user holds the View_Data_Cloud_Diagnostics
 * custom permission, so the template has to handle its absence rather than assume it.
 */
export default class DataCloudQueryPanel extends LightningElement {
    _queries = [];
    expanded = false;

    @api
    get queries() {
        return this._queries;
    }
    set queries(value) {
        this._queries = Array.isArray(value) ? value : [];
    }

    @api totalDurationMs;

    get hasQueries() {
        return this._queries.length > 0;
    }

    get summary() {
        const n = this._queries.length;
        const ms = this.totalDurationMs;
        const rows = this._queries.reduce((sum, q) => sum + (q.rowCount || 0), 0);
        return `${n} ${n === 1 ? 'query' : 'queries'} · ${this.formatRows(rows)}${ms ? ` · ${ms} ms` : ''}`;
    }

    get toggleLabel() {
        return this.expanded ? 'Hide queries' : 'Show queries';
    }

    /** Data Cloud bills on data processed, so the row count is the number that costs money. */
    get rows() {
        return this._queries.map((q, i) => ({
            key: `${q.dmo}-${i}`,
            purpose: q.purpose,
            dmo: q.dmo,
            meta: `${this.formatRows(q.rowCount)} · ${
                q.durationMs === null || q.durationMs === undefined ? '-' : `${q.durationMs} ms`
            }`,
            sql: q.sql,
            hasSql: Boolean(q.sql)
        }));
    }

    formatRows(count) {
        if (count === null || count === undefined) {
            return '- rows';
        }
        return `${count} ${count === 1 ? 'row' : 'rows'}`;
    }

    get anySqlWithheld() {
        return this._queries.some((q) => !q.sql);
    }

    handleToggle() {
        this.expanded = !this.expanded;
    }
}
