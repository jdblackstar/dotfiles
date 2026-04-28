# Remove AI code slop

make the added code in my brach beautiful by following these rules:

- write extremely simple code, it should be "skimmable" and you should still be able to understand it
- minimize possible states by reducing number of arguments, remove or narrow any state
- use discriminated unions to reduce number of states the code can be in
- exhaustively handle any objects with multiple different types, fail on unknown type 
- don't write defensive code, assume the values are always what types tell you they are
- use asserts when loading data, and always be highly opinionated about the parameters you pass around. don't let things be optional if not strictly required
- remove any changes that are not strictly required
- bias for fewer lines of code
- no complex or clever code
- don't break out into too many function, that's hard to read
- early returns are great
- use asserts instead of try catches or default values when you do expect something to exist
- never pass overrides except strictly necessary, keep argument count low
- don't make arguments optional if they are actually required

Report afterwards with only a 1-3 sentence summary of what you changed