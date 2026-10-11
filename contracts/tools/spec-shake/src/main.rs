//! spec-shake <in.wasm> <out.wasm>
//!
//! soroban-sdk's `experimental_spec_shaking_v2` (enabled by OpenZeppelin stellar-tokens) emits every spec entry plus
//! a marker for each one the contract actually uses. `stellar contract build` then strips the unused entries. This
//! does the same with soroban-spec's own `find_all` + `filter`, removes exact duplicates, and rewrites the
//! `contractspecv0` custom section. Everything else in the module is copied byte for byte.
use std::collections::HashSet;
use stellar_xdr::curr::{Limits, WriteXdr};
use wasm_encoder::{CustomSection, Module, RawSection};
use wasmparser::{Parser, Payload};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: spec-shake <in.wasm> <out.wasm>");
        std::process::exit(2);
    }
    let wasm = std::fs::read(&args[1]).expect("read wasm");
    let entries = soroban_spec::read::from_wasm(&wasm).expect("parse contractspecv0");
    let markers = soroban_spec::shaking::find_all(&wasm);
    let before = entries.len();
    let mut seen = HashSet::new();
    let mut spec = Vec::new();
    let mut kept = 0usize;
    for e in soroban_spec::shaking::filter(entries, &markers) {
        let bytes = e.to_xdr(Limits::none()).expect("encode entry");
        if seen.insert(bytes.clone()) {
            spec.extend_from_slice(&bytes);
            kept += 1;
        }
    }

    let mut module = Module::new();
    for payload in Parser::new(0).parse_all(&wasm) {
        let payload = payload.expect("parse wasm");
        match payload {
            Payload::Version { .. } | Payload::End(_) => {}
            Payload::CustomSection(c) if c.name() == "contractspecv0" => {
                module.section(&CustomSection { name: "contractspecv0".into(), data: spec.as_slice().into() });
            }
            other => {
                if let Some((id, range)) = other.as_section() {
                    module.section(&RawSection { id, data: &wasm[range] });
                }
            }
        }
    }
    let out = module.finish();
    std::fs::write(&args[2], &out).expect("write wasm");
    eprintln!("spec entries: {before} -> {kept} (markers: {}), {} -> {} bytes", markers.len(), wasm.len(), out.len());
}
