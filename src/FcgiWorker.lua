--

local class = require "class"
local net = require "net"

local Panicable = require "Panicable"
local FcgiSocketAcceptor = require "FcgiSocketAcceptor"

--

local c = class:FcgiWorker {
    id = false,
    args = false,
    epoll = false,
    sockets = {},
}:extends{ Panicable }

--

function c:init()
    Panicable.init(self)

    self:init_epoll()
    self:init_listeners()

    self:process()
end

function c:init_epoll()
    self.epoll = self:assert(net.epoll())
end

function c:init_listeners()
    for i,addr in ipairs(self.args.listeners) do
        local fu = "init_transport__" .. addr.transport

        if type(self[fu]) ~= "function" then
            self:panic("unknown transport: " .. addr.transport)
        end

        self[fu](self, addr)
    end
end

function c:init_transport__ip4_tcp( conf )
    local sock, fd = self:assert(net.ip4.tcp.socket(1))

    self:assert(self.epoll:watch(fd, net.f.EPOLLET | net.f.EPOLLRDHUP | net.f.EPOLLIN))

    self:assert(sock:set(net.f.SO_REUSEADDR, 1))
    self:assert(sock:bind(conf.interface, conf.port))
    self:assert(sock:listen(conf.backlog))

    self.sockets[fd] = FcgiSocketAcceptor:new {
        fd = fd,
        sock = sock,
        worker = self,
    }
end

function c:init_transport__ip6_tcp( conf )
    local sock, fd = self:assert(net.ip6.tcp.socket(1))

    self:assert(self.epoll:watch(fd, net.f.EPOLLET | net.f.EPOLLRDHUP | net.f.EPOLLIN))

    self:assert(sock:set(net.f.SO_REUSEADDR, 1))
    self:assert(sock:bind(conf.interface, conf.port))
    self:assert(sock:listen(conf.backlog))

    self.sockets[fd] = FcgiSocketAcceptor:new {
        fd = fd,
        sock = sock,
        worker = self,
    }
end

function c:init_transport__unix( conf )
    local sock, fd = self:assert(net.unix.socket(1))

    self:assert(self.epoll:watch(fd, net.f.EPOLLET | net.f.EPOLLRDHUP | net.f.EPOLLIN))

    os.remove(conf.path)
    self:assert(sock:bind(conf.path, conf.mode))
    self:assert(sock:listen(conf.backlog))

    self.sockets[fd] = FcgiSocketAcceptor:new {
        fd = fd,
        sock = sock,
        worker = self,
    }
end

function c:process()
    local this = self

    local timeout = -1

    local onread = function( fd )
        local obj = this.sockets[fd]

        if obj then
            obj:e_onread()
        else
            error("onread: unknown fd: " .. tostring(fd))
        end
    end

    local onwrite = function( fd )
        local obj = this.sockets[fd]

        if obj then
            obj:e_onwrite()
        else
            error("onwrite: unknown fd: " .. tostring(fd))
        end
    end

    local onhup = function( fd )
        local obj = this.sockets[fd]

        if obj then
            obj:e_onhup()
        else
            error("onhup: unknown fd: " .. tostring(fd))
        end
    end

    local onerror = function( fd, es, en )
        if fd then -- socket error
            local obj = this.sockets[fd]

            if obj then
                obj:e_onerror(es, en)
            else
                error("onerror: unknown fd: " .. tostring(fd))
            end
        else -- lua error
            print("onerror: lua:", es, en)
        end
    end

    local ontimeout = function()
        -- we have infinite timeout, this func shall never be called
    end

    while true do
        self:assert(self.epoll:start(timeout, onread, onwrite, ontimeout, onerror, onhup))
    end
end

--

return c