use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Absent,
    Null,
    Number(Number),
    String(String),
    Boolean(bool),
    Array(Vec<Value>),
    Object(HashMap<String, Value>),
}

#[derive(Clone, Debug, PartialEq)]
pub enum Number {
    Integer(i64),
    Float(f64),
}
