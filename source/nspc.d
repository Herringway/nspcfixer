module nspc;
import std;
import std.experimental.logger;

private auto getSequenceData(ushort addr, ushort baseAddress, CommandSet commandSet, ubyte[] phraseData, ushort phraseDataOffset, bool ignoreEnd = false) {
	static struct Sequence {
		ushort baseAddress;
		ushort phraseLocation;
		ubyte[] phraseData;
		CommandSet commandSet;
		size_t idx;
		void popFront() {
			idx += commandLengths[commandSet][phraseData[idx]];
		}
		bool empty() const {
			return (idx >= phraseData.length) || (phraseData[idx] !in commandLengths[commandSet]) || (idx + commandLengths[commandSet][phraseData[idx]] > phraseData.length);
		}
		auto front() {
			return Command(phraseData[idx .. idx + commandLengths[commandSet][phraseData[idx]]]);
		}
	}
	if (addr == 0) {
		return Sequence(baseAddress, 0, [], commandSet);
	}
	if (ignoreEnd) {
		return Sequence(baseAddress, addr, phraseData[addr - baseAddress - phraseDataOffset .. $], commandSet);
	} else {
		return Sequence(baseAddress, addr, phraseData[addr - baseAddress - phraseDataOffset .. addr - baseAddress - phraseDataOffset + phraseData[addr - baseAddress - phraseDataOffset .. $].countUntil(0) + 1], commandSet);
	}
}

struct Config {
	ubyte[ubyte] instrumentMapping;
	byte[12] noteMapping;
	bool randomizeNotes;
	byte upperNoteAdjustment = 1;
	byte lowerNoteAdjustment = -1;
}

struct Song {
	ushort _baseAddress;
	CommandSet commandSet;
	ushort baseAddress() {
		return _baseAddress;
	}
	ushort baseAddress(ushort newAddress) {
		bool[size_t] seen;
		void fixSequence(T)(T channel) {
			tracef("Fixing up addresses at $%04X (%d)", channel.phraseLocation, channel.phraseData.length);
			foreach (ref command; channel) {
				if (command.command == SequenceCommand.callSubroutine && (cast(size_t)(&command.address()) !in seen)) {
					tracef("Fixing address %04X -> %04X", command.address, cast(ushort)((command.address - baseAddress) + newAddress));
					//fixSequence(getSequenceData(command.address, baseAddress, commandSet, phraseData, phraseDataOffset));
					command.address = cast(ushort)((command.address - baseAddress) + newAddress);
					seen[cast(size_t)(&command.address())] = true;
				}
			}
		}
		fixSequence(getSequenceData(cast(ushort)(_baseAddress + phraseDataOffset), _baseAddress, commandSet, phraseData, phraseDataOffset, true));
		// while this is technically correct, it may miss some data that isn't referenced.
		//foreach (ref sequence; sequenceData) {
		//	foreach (ref channel; sequence) {
		//		fixSequence(channel);
		//	}
		//}
		foreach (ref phraseHeader; phraseHeaders) {
			if (phraseHeader > 0x100) {
				phraseHeader = cast(ushort)((phraseHeader - baseAddress) + newAddress);
			}
		}
		foreach (ref phraseAddress; phraseAddresses) {
			if (phraseAddress > 0) {
				phraseAddress = cast(ushort)((phraseAddress - baseAddress) + newAddress);
			}
		}
		_baseAddress = newAddress;
		return _baseAddress;
	}
	ushort[] phraseHeaders;
	ushort[] phraseAddresses;
	ubyte[] phraseData;
	ushort phraseDataOffset;
	private auto sequenceDataAt(ushort addr) {
		return getSequenceData(addr, _baseAddress, commandSet, phraseData, phraseDataOffset);
	}
	auto sequenceData() {
		static struct Phrase {
			ushort baseAddress;
			ushort phraseDataOffset;
			ushort[] phraseHeaders;
			ushort[] phraseAddresses;
			ubyte[] phraseData;
			CommandSet commandSet;
			size_t offset;
			size_t idx;
			void popFront() {
				offset++;
				idx++;
				while ((offset < phraseHeaders.length) && (phraseHeaders[offset] <= 0x100)) {
					offset += 2;
				}
			}
			auto front() {
				static struct PhraseChannel {
					ushort baseAddress;
					ushort phraseDataOffset;
					ushort[] phraseAddresses;
					ubyte[] phraseData;
					CommandSet commandSet;
					size_t idx;
					bool empty() const {
						return idx >= 8;
					}
					void popFront() {
						idx++;
					}
					auto front() {
						return getSequenceData(phraseAddresses[idx], baseAddress, commandSet, phraseData, phraseDataOffset);
					}
				}
				return PhraseChannel(baseAddress, phraseDataOffset, phraseAddresses[idx * 8 .. (idx + 1) * 8], phraseData, commandSet);
			}
			bool empty() const {
				return offset >= phraseHeaders.length;
			}
		}
		return Phrase(_baseAddress, phraseDataOffset, phraseHeaders, phraseAddresses, phraseData, commandSet);
	}
	void remapInstruments(const scope ubyte[ubyte] mapping) {
		bool[size_t] seen;
		void fixSequence(T)(T channel, bool recurse = false) {
			tracef("Remapping instruments at $%04X (%d)", channel.phraseLocation, channel.phraseData.length);
			foreach (ref command; channel) {
				if (command.command == SequenceCommand.instrument && (cast(size_t)(&command.instrument()) !in seen)) {
					const ubyte instrument = mapping.get(command.instrument, command.instrument);
					if (instrument != command.instrument) {
						tracef("Remapping instrument: %02X -> %02X", command.instrument, instrument);
					}
					command.instrument = instrument;
					seen[cast(size_t)(&command.instrument())] = true;
				}
				if (command.command == SequenceCommand.callSubroutine && (cast(size_t)(&command.address()) !in seen)) {
					if (recurse) {
						fixSequence(getSequenceData(command.address, baseAddress, commandSet, phraseData, phraseDataOffset));
					}
					seen[cast(size_t)(&command.instrument())] = true;
				}
			}
		}
		fixSequence(getSequenceData(cast(ushort)(_baseAddress + phraseDataOffset), _baseAddress, commandSet, phraseData, phraseDataOffset, true));
	}
	void transposeNotes(const byte[12] mapping) {
		bool[size_t] seen;
		void transposeNotes(T)(T channel, const byte[12] adjustments) {
			tracef("Transposing notes at $%04X (%d)", channel.phraseLocation, channel.phraseData.length);
			foreach (ref command; channel) {
				if (command.command.among(SequenceCommand.note, SequenceCommand.pitchSlide) && (cast(size_t)(&command.note()) !in seen)) {
					const newNote = cast(ubyte)clamp(command.note + adjustments[(command.note - 0x80)%12], 0x80, 0xC7);
					if (command.note != newNote) {
						tracef("Transposing note: %02X -> %02X", command.note, newNote);
						command.note = newNote;
					}
					seen[cast(size_t)(&command.note())] = true;
				}
			}
		}
		transposeNotes(getSequenceData(cast(ushort)(_baseAddress + phraseDataOffset), _baseAddress, commandSet, phraseData, phraseDataOffset, true), mapping);
	}
}

struct Command {
	ubyte[] raw;
	SequenceCommand command() {
		switch (raw[0]) {
			case 0x80: .. case 0xC7: return SequenceCommand.note;
			case 0xE0: return SequenceCommand.instrument;
			case 0xEF: return SequenceCommand.callSubroutine;
			case 0xF9: return SequenceCommand.pitchSlide;
			default: return SequenceCommand.unknown;
		}
	}
	ref ushort address() {
		assert(command == SequenceCommand.callSubroutine);
		return (cast(ushort[])(raw[1 .. 3]))[0];
	}
	ref ubyte instrument() {
		assert(command == SequenceCommand.instrument);
		return raw[1];
	}
	ref ubyte note() {
		switch(command) {
			case SequenceCommand.note:
				return raw[0];
			case SequenceCommand.pitchSlide:
				return raw[3];
			default: assert(0);
		}
	}
}

enum CommandSet {
	early = 0,
	basic = 1
}

enum SequenceCommand : ubyte {
	callSubroutine,
	instrument,
	pitchSlide,
	note,
	unknown
}

Song loadSong(ushort base, ubyte[] raw) {
	Song output;
	output.baseAddress = base;
	auto headerAddresses = cast(ushort[])raw[0 .. ($ / 2) * 2];
	size_t i;
	size_t numPhrases;
	for (i = 0; headerAddresses[i] != 0x0000; i++) {
		if ((headerAddresses[i] >= 0x100) && ((i == 0) || (headerAddresses[i - 1] >= 0x100)) && (!headerAddresses[0 .. i].canFind(headerAddresses[i]))) {
			numPhrases++;
		}
	}
	output.phraseHeaders = headerAddresses[0 .. i + 1];
	output.phraseAddresses = headerAddresses[i + 1 .. i + 1 + (numPhrases * 8)];
	output.phraseData = raw[(i + 1 + (numPhrases * 8)) * 2 .. $];
	output.phraseDataOffset = cast(ushort)((i + 1 + (numPhrases * 8)) * 2);
	output.commandSet = CommandSet.basic;
	return output;
}

ubyte[] toRaw(Song song) {
	ubyte[] result;
	result ~= cast(const(ubyte)[])song.phraseHeaders;
	result ~= cast(const(ubyte)[])song.phraseAddresses;
	result ~= song.phraseData;
	return result;
}

immutable ubyte[ubyte][] commandLengths;

shared static this() {
	static ubyte[ubyte][] generateCommandLengths() pure {
		ubyte[ubyte][] output;
		//Early command set
		output ~= [
			0x00: 1,
		];
		//Basic command set
		output ~= [
			0x00: 1,
			0x01: 2,
			0x02: 2,
			0x03: 2,
			0x04: 2,
			0x05: 2,
			0x06: 2,
			0x07: 2,
			0x08: 2,
			0x09: 2,
			0x0A: 2,
			0x0B: 2,
			0x0C: 2,
			0x0D: 2,
			0x0E: 2,
			0x0F: 2,
			0x10: 2,
			0x11: 2,
			0x12: 2,
			0x13: 2,
			0x14: 2,
			0x15: 2,
			0x16: 2,
			0x17: 2,
			0x18: 2,
			0x19: 2,
			0x1A: 2,
			0x1B: 2,
			0x1C: 2,
			0x1D: 2,
			0x1E: 2,
			0x1F: 2,
			0x20: 2,
			0x21: 2,
			0x22: 2,
			0x23: 2,
			0x24: 2,
			0x25: 2,
			0x26: 2,
			0x27: 2,
			0x28: 2,
			0x29: 2,
			0x2A: 2,
			0x2B: 2,
			0x2C: 2,
			0x2D: 2,
			0x2E: 2,
			0x2F: 2,
			0x30: 2,
			0x31: 2,
			0x32: 2,
			0x33: 2,
			0x34: 2,
			0x35: 2,
			0x36: 2,
			0x37: 2,
			0x38: 2,
			0x39: 2,
			0x3A: 2,
			0x3B: 2,
			0x3C: 2,
			0x3D: 2,
			0x3E: 2,
			0x3F: 2,
			0x40: 2,
			0x41: 2,
			0x42: 2,
			0x43: 2,
			0x44: 2,
			0x45: 2,
			0x46: 2,
			0x47: 2,
			0x48: 2,
			0x49: 2,
			0x4A: 2,
			0x4B: 2,
			0x4C: 2,
			0x4D: 2,
			0x4E: 2,
			0x4F: 2,
			0x50: 2,
			0x51: 2,
			0x52: 2,
			0x53: 2,
			0x54: 2,
			0x55: 2,
			0x56: 2,
			0x57: 2,
			0x58: 2,
			0x59: 2,
			0x5A: 2,
			0x5B: 2,
			0x5C: 2,
			0x5D: 2,
			0x5E: 2,
			0x5F: 2,
			0x60: 2,
			0x61: 2,
			0x62: 2,
			0x63: 2,
			0x64: 2,
			0x65: 2,
			0x66: 2,
			0x67: 2,
			0x68: 2,
			0x69: 2,
			0x6A: 2,
			0x6B: 2,
			0x6C: 2,
			0x6D: 2,
			0x6E: 2,
			0x6F: 2,
			0x70: 2,
			0x71: 2,
			0x72: 2,
			0x73: 2,
			0x74: 2,
			0x75: 2,
			0x76: 2,
			0x77: 2,
			0x78: 2,
			0x79: 2,
			0x7A: 2,
			0x7B: 2,
			0x7C: 2,
			0x7D: 2,
			0x7E: 2,
			0x7F: 2,
			0x80: 1,
			0x81: 1,
			0x82: 1,
			0x83: 1,
			0x84: 1,
			0x85: 1,
			0x86: 1,
			0x87: 1,
			0x88: 1,
			0x89: 1,
			0x8A: 1,
			0x8B: 1,
			0x8C: 1,
			0x8D: 1,
			0x8E: 1,
			0x8F: 1,
			0x90: 1,
			0x91: 1,
			0x92: 1,
			0x93: 1,
			0x94: 1,
			0x95: 1,
			0x96: 1,
			0x97: 1,
			0x98: 1,
			0x99: 1,
			0x9A: 1,
			0x9B: 1,
			0x9C: 1,
			0x9D: 1,
			0x9E: 1,
			0x9F: 1,
			0xA0: 1,
			0xA1: 1,
			0xA2: 1,
			0xA3: 1,
			0xA4: 1,
			0xA5: 1,
			0xA6: 1,
			0xA7: 1,
			0xA8: 1,
			0xA9: 1,
			0xAA: 1,
			0xAB: 1,
			0xAC: 1,
			0xAD: 1,
			0xAE: 1,
			0xAF: 1,
			0xB0: 1,
			0xB1: 1,
			0xB2: 1,
			0xB3: 1,
			0xB4: 1,
			0xB5: 1,
			0xB6: 1,
			0xB7: 1,
			0xB8: 1,
			0xB9: 1,
			0xBA: 1,
			0xBB: 1,
			0xBC: 1,
			0xBD: 1,
			0xBE: 1,
			0xBF: 1,
			0xC0: 1,
			0xC1: 1,
			0xC2: 1,
			0xC3: 1,
			0xC4: 1,
			0xC5: 1,
			0xC6: 1,
			0xC7: 1,
			0xC8: 1,
			0xC9: 1,
			0xCA: 1,
			0xCB: 1,
			0xCC: 1,
			0xCD: 1,
			0xCE: 1,
			0xCF: 1,
			0xD0: 1,
			0xD1: 1,
			0xD2: 1,
			0xD3: 1,
			0xD4: 1,
			0xD5: 1,
			0xD6: 1,
			0xD7: 1,
			0xD8: 1,
			0xD9: 1,
			0xDA: 1,
			0xDB: 1,
			0xDC: 1,
			0xDD: 1,
			0xDE: 1,
			0xDF: 1,
			0xE0: 2,
			0xE1: 2,
			0xE2: 3,
			0xE3: 4,
			0xE4: 1,
			0xE5: 2,
			0xE6: 3,
			0xE7: 2,
			0xE8: 3,
			0xE9: 2,
			0xEA: 2,
			0xEB: 4,
			0xEC: 1,
			0xED: 2,
			0xEE: 3,
			0xEF: 4,
			0xF0: 1,
			0xF1: 4,
			0xF2: 4,
			0xF3: 1,
			0xF4: 2,
			0xF5: 4,
			0xF6: 1,
			0xF7: 4,
			0xF8: 4,
			0xF9: 4,
			0xFA: 2,
		];
		return output;
	}
	commandLengths = generateCommandLengths();
}
