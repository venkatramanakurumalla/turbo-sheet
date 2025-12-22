use flutter_rust_bridge::frb;

pub struct CellData {
    pub content: String,
}

pub struct RowData {
    pub index: i64,
    pub cells: Vec<CellData>,
}

pub struct SheetSession {
    pub total_rows: i64,
    pub total_cols: i64,
}

impl SheetSession {
    // REMOVED #[frb(sync)] -- Now runs on background thread
    pub fn new_demo(rows: i64, cols: i64) -> SheetSession {
        SheetSession {
            total_rows: rows,
            total_cols: cols,
        }
    }

    // REMOVED #[frb(sync)] -- Now returns Future<Vec<String>> in Dart
    pub fn get_header_chunk(&self, col_start: i64, col_count: i32) -> Vec<String> {
        let mut headers = Vec::new();
        for i in 0..col_count {
            let actual_idx = col_start + (i as i64);
            if actual_idx >= self.total_cols { break; }
            headers.push(Self::number_to_col_name(actual_idx));
        }
        headers
    }

    // REMOVED #[frb(sync)] -- Already efficient, but now won't block UI
    pub fn get_grid_chunk(
        &self, 
        row_start: i64, 
        row_count: i32, 
        col_start: i64, 
        col_count: i32
    ) -> Vec<RowData> {
        let mut results = Vec::new();
        
        for r in 0..row_count {
            let current_row_idx = row_start + (r as i64);
            if current_row_idx >= self.total_rows { break; }

            let mut cells = Vec::new();
            for c in 0..col_count {
                let current_col_idx = col_start + (c as i64);
                if current_col_idx >= self.total_cols { break; }

                let content = format!("{},{}", 
                    Self::number_to_col_name(current_col_idx), 
                    current_row_idx
                );
                
                cells.push(CellData { content });
            }

            results.push(RowData {
                index: current_row_idx,
                cells,
            });
        }
        results
    }

    fn number_to_col_name(mut n: i64) -> String {
        let mut result = String::new();
        loop {
            let remainder = (n % 26) as u8;
            result.insert(0, (b'A' + remainder) as char);
            n = n / 26 - 1;
            if n < 0 { break; }
        }
        result
    }
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
