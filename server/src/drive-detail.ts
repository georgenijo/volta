import type { DB, Row } from './db';
import { Dem } from './elevation';
import { FleetDrives, telemetryDriveVehicle } from './fleet-drives';

/** Detail-only additions to GET /v1/drives/{id}, applied after
 * Telemetry.drive() resolved (and authorised) the drive:
 * - telemetry drives (id<0): `charts` plus DEM `elevationGainM`/`elevationLossM`
 *   for the same merged window (same id and start), over the detail's own span;
 * - TeslaMate drives: `charts: null` and `elevationLossM` from `drives.descent`.
 * An optional-data failure keeps the detail and reports the extras as unknown. */
export class DriveDetail {
  constructor(private sql: DB, private dem: Dem | null = Dem.fromEnv(), private log: (entry: object) => void = () => {}) {}
  async extend(detail: Row): Promise<Row> {
    if (detail.id<0) {
      try {
        const vehicle=telemetryDriveVehicle(detail.id), store=new FleetDrives(this.sql), catalog=await store.catalog(vehicle);
        const window=catalog?.windows.find(w=>w.id===detail.id);
        // An open drive's end advances between telemetry.drive() and this
        // catalog read: match the same trip by id and start, then chart the
        // detail's own span. An end beyond the current window is a mismatch.
        if (catalog && window && +window.start===+new Date(detail.start) && +new Date(detail.end)<=+window.end && +new Date(detail.end)>=+window.start)
          return {...detail,...await store.detailExtras(vehicle,{...window,end:new Date(detail.end)},catalog.gaps,this.dem)};
      } catch { this.log({event:'drive_detail_extras_unavailable',category:'optional_telemetry'}); }
      return {...detail,charts:null,elevationGainM:detail.elevationGainM ?? null,elevationLossM:null};
    }
    let loss: number | null=null;
    try {
      const [row]=await this.sql`SELECT descent AS "elevationLossM" FROM public.drives WHERE id=${detail.id}`;
      loss=row?.elevationLossM ?? null;
    } catch { this.log({event:'drive_detail_extras_unavailable',category:'teslamate'}); }
    return {...detail,charts:null,elevationLossM:loss};
  }
}
