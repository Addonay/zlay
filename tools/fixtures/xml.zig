//! Minimal XML reader for Taffy's generated fixture format.
//!
//! The fixtures under `.references/taffy/tests/xml/**` use a strict subset of
//! XML: a prolog, elements with quoted attributes, self-closing elements,
//! text content and occasional comments. Namespaces, CDATA and DTDs do not
//! occur. This parser therefore stays small and never allocates outside the
//! caller-provided arena.

const std = @import("std");

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const Element = struct {
    name: []const u8,
    attributes: []const Attribute,
    children: []Element,
    text: []const u8 = "",

    pub fn attribute(self: *const Element, name: []const u8) ?[]const u8 {
        for (self.attributes) |item| {
            if (std.mem.eql(u8, item.name, name)) return item.value;
        }
        return null;
    }

    pub fn firstChild(self: *const Element, name: []const u8) ?*const Element {
        for (self.children) |*child| {
            if (std.mem.eql(u8, child.name, name)) return child;
        }
        return null;
    }

    pub fn firstElementChild(self: *const Element) ?*const Element {
        if (self.children.len == 0) return null;
        return &self.children[0];
    }
};

pub fn parse(alloc: std.mem.Allocator, input: []const u8) !*Element {
    var parser = Parser{ .alloc = alloc, .input = input };
    try parser.skipMisc();
    const root = try parser.parseElement();
    return root;
}

const Parser = struct {
    alloc: std.mem.Allocator,
    input: []const u8,
    pos: usize = 0,

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.input.len) self.input[self.pos] else null;
    }

    fn startsWith(self: *Parser, text: []const u8) bool {
        return std.mem.startsWith(u8, self.input[self.pos..], text);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len and std.ascii.isWhitespace(self.input[self.pos])) self.pos += 1;
    }

    fn skipUntil(self: *Parser, terminator: []const u8) !void {
        if (std.mem.indexOfPos(u8, self.input, self.pos, terminator)) |index| {
            self.pos = index + terminator.len;
            return;
        }
        return error.UnexpectedEof;
    }

    /// Skip prolog, comments, doctype and whitespace between top-level items.
    fn skipMisc(self: *Parser) !void {
        while (true) {
            self.skipWhitespace();
            if (self.startsWith("<?")) {
                try self.skipUntil("?>");
            } else if (self.startsWith("<!--")) {
                try self.skipUntil("-->");
            } else if (self.startsWith("<!")) {
                try self.skipUntil(">");
            } else break;
        }
    }

    fn parseName(self: *Parser) ![]const u8 {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == ':' or ch == '.') {
                self.pos += 1;
            } else break;
        }
        if (self.pos == start) return error.InvalidXml;
        return self.input[start..self.pos];
    }

    fn decodeEntities(self: *Parser, raw: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '&') == null) return raw;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.alloc);
        var index: usize = 0;
        while (index < raw.len) {
            if (raw[index] != '&') {
                try out.append(self.alloc, raw[index]);
                index += 1;
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, raw, index, ';') orelse return error.InvalidXml;
            const entity = raw[index + 1 .. end];
            if (std.mem.eql(u8, entity, "amp")) {
                try out.append(self.alloc, '&');
            } else if (std.mem.eql(u8, entity, "lt")) {
                try out.append(self.alloc, '<');
            } else if (std.mem.eql(u8, entity, "gt")) {
                try out.append(self.alloc, '>');
            } else if (std.mem.eql(u8, entity, "quot")) {
                try out.append(self.alloc, '"');
            } else if (std.mem.eql(u8, entity, "apos")) {
                try out.append(self.alloc, '\'');
            } else if (entity.len > 1 and entity[0] == '#') {
                const code_point = if (entity[1] == 'x' or entity[1] == 'X')
                    std.fmt.parseInt(u21, entity[2..], 16) catch return error.InvalidXml
                else
                    std.fmt.parseInt(u21, entity[1..], 10) catch return error.InvalidXml;
                var buffer: [4]u8 = undefined;
                const encoded_len = std.unicode.utf8Encode(code_point, &buffer) catch return error.InvalidXml;
                try out.appendSlice(self.alloc, buffer[0..encoded_len]);
            } else return error.InvalidXml;
            index = end + 1;
        }
        return out.items;
    }

    fn parseAttributeValue(self: *Parser) ![]const u8 {
        const quote = self.input[self.pos];
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != quote) self.pos += 1;
        if (self.pos >= self.input.len) return error.UnexpectedEof;
        const raw = self.input[start..self.pos];
        self.pos += 1;
        return self.decodeEntities(raw);
    }

    fn parseElement(self: *Parser) !*Element {
        if (self.peek() != @as(u8, '<')) return error.InvalidXml;
        self.pos += 1;

        const element = try self.alloc.create(Element);
        element.* = .{ .name = undefined, .attributes = &.{}, .children = &.{} };
        element.name = try self.parseName();

        var attributes = std.ArrayList(Attribute).empty;
        errdefer attributes.deinit(self.alloc);
        while (true) {
            self.skipWhitespace();
            if (self.startsWith("/>")) {
                self.pos += 2;
                element.attributes = try self.alloc.dupe(Attribute, attributes.items);
                element.children = &.{};
                return element;
            }
            if (self.startsWith(">")) {
                self.pos += 1;
                break;
            }
            if (self.peek() == null) return error.UnexpectedEof;
            const name = try self.parseName();
            self.skipWhitespace();
            if (self.peek() != @as(u8, '=')) return error.InvalidXml;
            self.pos += 1;
            self.skipWhitespace();
            const value = try self.parseAttributeValue();
            try attributes.append(self.alloc, .{ .name = name, .value = value });
        }
        element.attributes = try self.alloc.dupe(Attribute, attributes.items);

        var children = std.ArrayList(Element).empty;
        errdefer children.deinit(self.alloc);
        var text = std.ArrayList(u8).empty;
        errdefer text.deinit(self.alloc);

        while (true) {
            if (self.pos >= self.input.len) return error.UnexpectedEof;
            if (self.startsWith("</")) {
                self.pos += 2;
                const close_name = try self.parseName();
                if (!std.mem.eql(u8, close_name, element.name)) return error.InvalidXml;
                self.skipWhitespace();
                if (self.peek() != @as(u8, '>')) return error.InvalidXml;
                self.pos += 1;
                break;
            } else if (self.startsWith("<!--")) {
                try self.skipUntil("-->");
            } else if (self.startsWith("<?")) {
                try self.skipUntil("?>");
            } else if (self.startsWith("<!")) {
                try self.skipUntil(">");
            } else if (self.startsWith("<")) {
                const child = try self.parseElement();
                try children.append(self.alloc, child.*);
                self.alloc.destroy(child);
            } else {
                const start = self.pos;
                while (self.pos < self.input.len and self.input[self.pos] != @as(u8, '<')) self.pos += 1;
                try text.appendSlice(self.alloc, self.input[start..self.pos]);
            }
        }

        element.children = try self.alloc.dupe(Element, children.items);
        element.text = try self.decodeEntities(text.items);
        return element;
    }
};

test "parses fixture-shaped xml" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(),
        \\<?xml version="1.0"?>
        \\<test name="x" use-rounding="true">
        \\  <viewport width="max-content" height="100"/>
        \\  <input>
        \\    <div direction="ltr" width="110px">hello &amp; world</div>
        \\  </input>
        \\  <expectations>
        \\    <node x="0" y="0" width="110" height="100"/>
        \\  </expectations>
        \\</test>
    );
    try testing.expectEqualStrings("test", doc.name);
    try testing.expectEqualStrings("true", doc.attribute("use-rounding").?);
    const input = doc.firstChild("input").?;
    const div = input.firstElementChild().?;
    try testing.expectEqualStrings("110px", div.attribute("width").?);
    try testing.expectEqualStrings("hello & world", div.text);
}
