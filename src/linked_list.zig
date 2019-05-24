// Source: https://github.com/ziglang/zig/blob/9e8750fe2efa921a72dae4fe8f11876a07a309b8/std/linked_list.zig

const std = @import("std");
const debug = std.debug;
const assert = debug.assert;
const testing = std.testing;
const mem = std.mem;
const Allocator = mem.Allocator;

/// A singly-linked list is headed by a single forward pointer. The elements
/// are singly linked for minimum space and pointer manipulation overhead at
/// the expense of O(n) removal for arbitrary elements. New elements can be
/// added to the list after an existing element or at the head of the list.
/// A singly-linked list may only be traversed in the forward direction.
/// Singly-linked lists are ideal for applications with large datasets and
/// few or no removals or for implementing a LIFO queue.
pub fn SinglyLinkedList(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Node inside the linked list wrapping the actual data.
        pub const Node = struct {
            next: ?*Node,
            data: T,

            pub fn init(data: T) Node {
                return Node{
                    .next = null,
                    .data = data,
                };
            }

            /// Insert a new node after the current one.
            ///
            /// Arguments:
            ///     new_node: Pointer to the new node to insert.
            pub fn insertAfter(node: *Node, new_node: *Node) void {
                new_node.next = node.next;
                node.next = new_node;
            }

            /// Remove a node from the list.
            ///
            /// Arguments:
            ///     node: Pointer to the node to be removed.
            /// Returns:
            ///     node removed
            pub fn removeNext(node: *Node) ?*Node {
                const next_node = node.next orelse return null;
                node.next = next_node.next;
                return next_node;
            }
        };

        first: ?*Node,

        /// Initialize a linked list.
        ///
        /// Returns:
        ///     An empty linked list.
        pub fn init() Self {
            return Self{
                .first = null,
            };
        }

        /// Insert a new node after an existing one.
        ///
        /// Arguments:
        ///     node: Pointer to a node in the list.
        ///     new_node: Pointer to the new node to insert.
        pub fn insertAfter(list: *Self, node: *Node, new_node: *Node) void {
            node.insertAfter(new_node);
        }

        /// Insert a new node at the head.
        ///
        /// Arguments:
        ///     new_node: Pointer to the new node to insert.
        pub fn prepend(list: *Self, new_node: *Node) void {
            new_node.next = list.first;
            list.first = new_node;
        }

        /// Remove a node from the list.
        ///
        /// Arguments:
        ///     node: Pointer to the node to be removed.
        pub fn remove(list: *Self, node: *Node) void {
            if (list.first == node) {
                list.first = node.next;
            } else {
                var current_elm = list.first.?;
                while (current_elm.next != node) {
                    current_elm = current_elm.next.?;
                }
                current_elm.next = node.next;
            }
        }

        /// Remove and return the first node in the list.
        ///
        /// Returns:
        ///     A pointer to the first node in the list.
        pub fn popFirst(list: *Self) ?*Node {
            const first = list.first orelse return null;
            list.first = first.next;
            return first;
        }

        /// Allocate a new node.
        ///
        /// Arguments:
        ///     allocator: Dynamic memory allocator.
        ///
        /// Returns:
        ///     A pointer to the new node.
        pub fn allocateNode(list: *Self, allocator: *Allocator) !*Node {
            return allocator.create(Node);
        }

        /// Deallocate a node.
        ///
        /// Arguments:
        ///     node: Pointer to the node to deallocate.
        ///     allocator: Dynamic memory allocator.
        pub fn destroyNode(list: *Self, node: *Node, allocator: *Allocator) void {
            allocator.destroy(node);
        }

        /// Allocate and initialize a node and its data.
        ///
        /// Arguments:
        ///     data: The data to put inside the node.
        ///     allocator: Dynamic memory allocator.
        ///
        /// Returns:
        ///     A pointer to the new node.
        pub fn createNode(list: *Self, data: T, allocator: *Allocator) !*Node {
            var node = try list.allocateNode(allocator);
            node.* = Node.init(data);
            return node;
        }
    };
}

test "basic SinglyLinkedList test" {
    const allocator = debug.global_allocator;
    var list = SinglyLinkedList(u32).init();

    var one = try list.createNode(1, allocator);
    var two = try list.createNode(2, allocator);
    var three = try list.createNode(3, allocator);
    var four = try list.createNode(4, allocator);
    var five = try list.createNode(5, allocator);
    defer {
        list.destroyNode(one, allocator);
        list.destroyNode(two, allocator);
        list.destroyNode(three, allocator);
        list.destroyNode(four, allocator);
        list.destroyNode(five, allocator);
    }

    list.prepend(two); // {2}
    list.insertAfter(two, five); // {2, 5}
    list.prepend(one); // {1, 2, 5}
    list.insertAfter(two, three); // {1, 2, 3, 5}
    list.insertAfter(three, four); // {1, 2, 3, 4, 5}

    // Traverse forwards.
    {
        var it = list.first;
        var index: u32 = 1;
        while (it) |node| : (it = node.next) {
            testing.expect(node.data == index);
            index += 1;
        }
    }

    _ = list.popFirst(); // {2, 3, 4, 5}
    _ = list.remove(five); // {2, 3, 4}
    _ = two.removeNext(); // {2, 4}

    testing.expect(list.first.?.data == 2);
    testing.expect(list.first.?.next.?.data == 4);
    testing.expect(list.first.?.next.?.next == null);
}
