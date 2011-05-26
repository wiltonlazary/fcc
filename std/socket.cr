module std.socket;

import std.string, c.unistd, c.sys.socket, c.netdb, c.string, c.errno;

class Address {
  (sockaddr*, int) getAddrHandle() { _interrupt 3; return (null, 0); }
  Address dup() { _interrupt 3; }
}

class TcpAddress : Address {
  sockaddr_in saddr;
  (sockaddr*, int) getAddrHandle() {
    return (sockaddr*:&saddr, size-of sockaddr_in);
  }
  Address dup() using new TcpAddress {
    saddr = this.saddr;
    return that;
  }
  void init() { }
  void init(string dns, short port) {
    auto he = gethostbyname(toStringz(dns));
    using saddr {
      sin_addr.s_addr = *uint*:he.h_addr_list[0];
      sin_family = AF_INET;
      sin_port = htons(port);
    }
  }
}

alias __NFDBITS = 8 * size-of __fd_mask;
__fd_mask __FDMASK(int d) { return __fd_mask: (1 << (d % __NFDBITS)); }
void __FD_SET(int d, fd_set* set) { set.__fds_bits[d / __NFDBITS] |= __FDMASK d; }
bool __FD_ISSET(int d, fd_set* set) { return eval set.__fds_bits[d / __NFDBITS] & __FDMASK d; }
alias FD_SET = __FD_SET;
alias FD_ISSET = __FD_ISSET;

class Socket {
  int sockfd;
  Address boundAddr;
  void close() {
    c.unistd.close(sockfd);
  }
  void init() {
    sockfd = socket (AF_INET, SOCK_STREAM, 0);
  }
  void reuse(bool b) {
    setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &b, size-of bool);
  }
  // alias isOpen = sockfd;
  void open(TcpAddress ta) {
    auto res = .connect (sockfd, sockaddr*:&ta.saddr, size-of type-of ta.saddr);
  }
  int recv(void[] buf) {
    auto res = .recv(sockfd, buf.ptr, buf.length, 0);
    if (res <= 0) {
      close;
    }
    return res;
  }
  int send(void[] buf) {
    auto res = .send(sockfd, buf.ptr, buf.length, 0);
    if (res <= 0) {
      close;
    }
    return res;
  }
  void sendAll(void[] buf) {
    while buf.length {
      auto res = send buf;
      if (res <= 0) return;
      buf = buf[res .. $];
    }
  }
  void bind(Address addr) {
    boundAddr = addr;
    auto err = .bind(sockfd, addr.getAddrHandle());
    if (err == -1)
      raise-error new Error "While binding to $addr: $(CToString strerror errno)";
  }
  void listen(int backlog = 4) {
    auto err = .listen(sockfd, backlog);
    if (err == -1)
      raise-error new Error "While trying to listen: $(CToString strerror errno)";
  }
  Socket accept() using new Socket {
    boundAddr = this.boundAddr.dup;
    auto hdl = boundAddr.getAddrHandle();
    int gotLength = hdl[1];
    sockfd = .accept(this.sockfd, hdl[0], &gotLength);
    if (sockfd == -1) {
      raise-error new Error "While accepting connections on $(this.sockfd): $(CToString strerror errno)";
    }
    if (gotLength != hdl[1])
      raise-error new Error "Accepted socket address was of different type than listening socket: $gotLength, but expected $(hdl[1])! ";
    return that;
  }
}

struct SelectSet {
  fd_set rdset, wrset, errset;
  int largest;
  void add(Socket sock, bool read = false, bool write = false, bool error = false) {
    auto sockfd = sock.sockfd;
    if read  FD_SET(sockfd, &rdset);
    if write FD_SET(sockfd, &wrset);
    if error FD_SET(sockfd, &errset);
    if sockfd > largest largest = sockfd;
  }
  bool isReady(Socket sock, bool read = false, bool write = false, bool error = false) {
    auto sockfd = sock.sockfd;
    if  read && FD_ISSET(sockfd, &rdset) return true;
    if write && FD_ISSET(sockfd, &wrset) return true;
    if error && FD_ISSET(sockfd, &errset)return true;
    return false;
  }
  void select(float timeout = 30.0) {
    timeval tv;
    tv.tv_sec = int:timeout;
    tv.tv_usec = int:((timeout - tv.tv_sec) * 1_000_000);
    auto res = .select(largest + 1, &rdset, &wrset, &errset, &tv);
    if (res == -1) raise-error new Error "While trying to select: $(CToString strerror errno)";
  }
}
