use flutter_rust_bridge::frb;
use std::fs::File;
use memmap2::Mmap;
use std::sync::Arc;
use std::str;

// ------------------------------------
// Data Objects (Sent to Dart)
// ------------------------------------

pub struct CellData {
    pub content: String,
}

pub struct RowData {
    pub index: i64,
    pub cells: Vec<CellData>,
}

// ------------------------------------
// Session Logic (Stays in Rust)
// ------------------------------------

// This struct holds the file handle and the index.
// Dart only holds a reference to this.
pub struct SheetSession {
    pub total_rows: i64,
    pub total_cols: i64,
    
    // Internal fields hidden from Dart
    mmap: Arc<Mmap>,
    row_offsets: Vec<usize>, // The "Cheat Sheet" for where rows start
}

impl SheetSession {
    // 1. OPEN FILE & INDEX IT
    // This scans the file for newlines (\n) to build an index.
    pub fn new_from_file(path: String) -> Result<SheetSession, String> {
        // Try to open the file
        let file = File::open(&path).map_err(|e| format!("Failed to open file: {}", e))?;
        
        // Memory Map the file (treat disk like RAM)
        // UNSAFE: Standard requirement for mmap. We promise not to modify the file underneath.
        let mmap = unsafe { 
            Mmap::map(&file).map_err(|e| format!("Failed to map file: {}", e))? 
        };
        let mmap_arc = Arc::new(mmap);

        // Build Line Index
        // We scan for byte 10 (\n) to mark the start of every row.
        let mut row_offsets = Vec::new();
        row_offsets.push(0); // Row 0 starts at the beginning
        
        for (i, &byte) in mmap_arc.iter().enumerate() {
            if byte == b'\n' {
                row_offsets.push(i + 1);
            }
        }

        // Calculations
        let total_rows = row_offsets.len() as i64;
        
        // Estimate Columns from the first row
        // We look at the first line and count commas.
        let first_line_end = *row_offsets.get(1).unwrap_or(&mmap_arc.len());
        let first_line_slice = &mmap_arc[0..first_line_end];
        
        // If the file is empty or weird, default to 1 col
        let total_cols = if total_rows > 0 {
             byte_count_char(first_line_slice, b',') + 1
        } else {
             0
        };

        Ok(SheetSession {
            total_rows,
            total_cols,
            mmap: mmap_arc,
            row_offsets,
        })
    }

    // 2. READ DATA CHUNK
    // Reads only the specific bytes needed for the requested rows.
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
            
            // Stop if we go past the end of the file
            if current_row_idx >= self.total_rows { break; }
            
            // --- CORE LOGIC: SLICE THE FILE ---
            let start_byte = self.row_offsets[current_row_idx as usize];
            
            // The end byte is the start of the NEXT row, minus 1 (for the \n)
            let end_byte = if (current_row_idx as usize) + 1 < self.row_offsets.len() {
                self.row_offsets[(current_row_idx as usize) + 1].saturating_sub(1)
            } else {
                self.mmap.len()
            };

            // Safety check for empty lines or bad offsets
            if start_byte >= end_byte { 
                 results.push(RowData { index: current_row_idx, cells: vec![] });
                 continue; 
            }

            // Get the bytes directly from memory map
            let line_bytes = &self.mmap[start_byte..end_byte];
            // Convert to string (lossy handles invalid characters without crashing)
            let line_str = String::from_utf8_lossy(line_bytes);

            // Split by comma
            let all_cols: Vec<&str> = line_str.split(',').collect();

            // Extract only the visible columns
            let mut cells = Vec::new();
            for c in 0..col_count {
                let target_col = (col_start + (c as i64)) as usize;
                
                let content = if target_col < all_cols.len() {
                    all_cols[target_col].to_string()
                } else {
                    String::new() // Padding for short rows
                };
                
                cells.push(CellData { content });
            }

            results.push(RowData {
                index: current_row_idx,
                cells,
            });
        }
        results
    }

    // 3. GENERATE HEADERS (A, B, C... AA, AB...)
    pub fn get_header_chunk(&self, col_start: i64, col_count: i32) -> Vec<String> {
        let mut headers = Vec::new();
        for i in 0..col_count {
            let actual_idx = col_start + (i as i64);
            if actual_idx >= self.total_cols { break; }
            headers.push(Self::number_to_col_name(actual_idx));
        }
        headers
    }

    // Helper: 0 -> A, 26 -> AA
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

// ------------------------------------
// Setup & Utils
// ------------------------------------

fn byte_count_char(slice: &[u8], target: u8) -> i64 {
    slice.iter().filter(|&&b| b == target).count() as i64
}

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
