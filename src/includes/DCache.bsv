import CacheTypes::*;
import Vector::*;
import FShow::*;
import MemTypes::*;
import Types::*;
import ProcTypes::*;
import Fifo::*;
import Ehr::*;
import RefTypes::*;


typedef enum{Ready, StartMiss, SendFillReq, WaitFillResp, Resp} CacheStatus 
    deriving(Eq, Bits);
module mkDCache#(CoreID id)(
		MessageGet fromMem,
		MessagePut toMem,
		RefDMem refDMem, // debug: reference data mem
		DCache ifc);

    // Track the cache state
    Reg#(CacheStatus) status <- mkReg(Ready);

    // The cache memory
    Vector#(CacheRows, Reg#(CacheLine)) dataArray <- replicateM(mkRegU);
    Vector#(CacheRows, Reg#(CacheTag)) tagArray <- replicateM(mkRegU);
    Vector#(CacheRows, Reg#(MSI)) privArray <- replicateM(mkReg(I));

    // Book keeping
    Fifo#(2, Data) hitQ <- mkBypassFifo;
    Fifo#(1, MemReq) reqQ <- mkBypassFifo;
    Reg#(MemReq) missReq <- mkRegU;

    // for LR/SC, which enable atomic memory access for multicore cooperation
    Reg#(Maybe#(CacheLineAddr)) linkAddr <- mkReg(Invalid);
    // for alerting processor whether Sc failed or succeeded
    Fifo#(2, Data) scStateQ <-mkBypassFifo;

    rule doReq (status == Ready);

        // get request from queue
        MemReq r = reqQ.first;
        reqQ.deq;

        // calculate cache index and tag
        //$display("[Cache] Processing request core %d", id);
        CacheWordSelect sel = getWordSelect(r.addr);
        CacheIndex idx = getIndex(r.addr);
        CacheTag tag = getTag(r.addr);

        // check if in cache
        let hit = False;
        if (tagArray[idx] == tag && privArray[idx] > I) hit = True;

        if (hit) begin
            if (r.op == Ld) begin
                //$display("[Cache] Load hit");
                hitQ.enq(dataArray[idx][sel]);
                refDMem.commit(r, Valid(dataArray[idx]), 
                                Valid(dataArray[idx][sel]));
            end 
            // Lr hit
            else if (r.op == Lr) begin
                $display("[Cache] Load-reserve hit");
                hitQ.enq(dataArray[idx][sel]);
                refDMem.commit(r, Valid(dataArray[idx]),
                                Valid(dataArray[idx][sel]));
                linkAddr <= tagged Valid getLineAddr(r.addr);
            end
            // Sc hit handling
            else if (r.op == Sc) begin
                $display("[Cache] Store-conditional hit");
                let reserved_addr = getLineAddr(r.addr);
                if (linkAddr matches tagged Valid .la) begin
                    // process as normal store request
                    $display("[Cache] Store-conditional address OK");
                    if (privArray[idx] == M) begin
                        $display("[Cache] Sc hit");
                        dataArray[idx][sel] <= r.data;
                        refDMem.commit(r, Valid(dataArray[idx]), Valid(scSucc));
                        // respond to core with value scSucc
                        hitQ.enq(scSucc);
                    end
                    else begin
                        $display("[Cache] No write privledge");
                        missReq <= r;
                        status <= SendFillReq;
                    end
                end else begin
                    $display("[Cache] Sc address does not match linkAddr");
                    // directly respond to core with value scFail
                    hitQ.enq(scFail);
                    refDMem.commit(r, Invalid, Valid(scFail));
                end
                // regardless of success, linkAddr no longer valid
                linkAddr <= tagged Invalid;
            end
            else begin // store
                if (privArray[idx] == M) begin
                    //$display("[Cache] Write hit");
                    // check whether by evicting old line, we must also invalidate linkAddr
                    CacheLineAddr reserved_addr = getLineAddr(missReq.addr);
                    if (linkAddr matches tagged Valid .la) begin
                        if (la == reserved_addr) begin
                            linkAddr <= tagged Invalid;
                            $display("[Cache] St address matches la; la invalidated");
                        end
                    end
                    dataArray[idx][sel] <= r.data;
                    refDMem.commit(r, Valid(dataArray[idx]), Invalid);
                end
                else begin
                    //$display("[Cache] No write privledge");
                    missReq <= r;
                    status <= SendFillReq;
                end
            end
        end
        else begin
            //$display("[Cache] Cache miss");
            missReq <= r;
            status <= StartMiss;
        end
    endrule


    rule startMiss (status == StartMiss);

        // calculate cache index and tag
        //$display("[[Cache]] Start Miss");
        CacheWordSelect sel = getWordSelect(missReq.addr);
        CacheIndex idx = getIndex(missReq.addr);
        let tag = tagArray[idx];

        if (privArray[idx] != I) begin
           
           // Invalidate cache line
           privArray[idx] <= I;

           // Determine if a valid cache line needs to write back
           Maybe#(CacheLine) line;
           if (privArray[idx] == M) line = Valid(dataArray[idx]);
           else line = Invalid;
           
           // Send cache line back to main memory
           let addr = {tag, idx, sel, 2'b0};
           toMem.enq_resp( CacheMemResp {child: id, 
                                  addr: addr, 
                                  state: I,
                                  data: line});
        end
        status <= SendFillReq;

    endrule


    rule sendFillReq (status == SendFillReq);

        //$display("[[Cache]] Send Fill Request");

        // send upgrade request, S if load; otherwise M
        let upg = ((missReq.op == Ld) || (missReq.op == Lr))? S : M;
        toMem.enq_req( CacheMemReq {child: id, addr:missReq.addr, state: upg});
        status <= WaitFillResp;

    endrule


    rule waitFillResp (status == WaitFillResp && fromMem.hasResp);
        
        // calculate cache index and tag
        //$display("[[Cache]] Wait Fill Response");
        CacheWordSelect sel = getWordSelect(missReq.addr);
        CacheIndex idx = getIndex(missReq.addr);
        let tag = getTag(missReq.addr);
        
        // get response
        CacheMemResp x = ?;
        case (fromMem.first) matches
            tagged Resp .resp : x = resp;
        endcase
        
        // create cache line
        CacheLine line;
        if (isValid(x.data)) line = fromMaybe(?, x.data);
        else line = dataArray[idx];
        CacheLineAddr reserved_addr = getLineAddr(missReq.addr);
        if (missReq.op == St) begin
            let old_line = isValid(x.data) ? fromMaybe(?, x.data) : dataArray[idx];
            // check whether by evicting old line, we must also invalidate linkAddr
            if (linkAddr matches tagged Valid .la) begin
                if (la == reserved_addr) begin
                    linkAddr <= tagged Invalid;
                end
            end
            refDMem.commit(missReq, Valid(old_line), Invalid);
            line[sel] = missReq.data;
        end
        // Sc miss handling
        else if (missReq.op == Sc) begin
            CacheLineAddr reserved_addr = getLineAddr(missReq.addr);
            if (linkAddr matches tagged Valid .la) begin
                if (la == reserved_addr) begin
                    $display("[Cache] Sc success");
                    line[sel] = missReq.data;
                    refDMem.commit(missReq, Valid(dataArray[idx]), Valid(scSucc));
                    // respond to core with value scSucc
                    hitQ.enq(scSucc);
                end
                else begin
                    $display("[Cache] Sc address does not match linkAddr");
                    // respond to core with value scFail
                    refDMem.commit(missReq, Invalid, Valid(scFail));
                    hitQ.enq(scFail);
                end
            end
            linkAddr <= tagged Invalid;
        end
                        
        dataArray[idx] <= line;
        
        // update cache line tag and privledge
        tagArray[idx] <= tag;
        privArray[idx] <= x.state;
        
        // dequeue memory response
        fromMem.deq;

        // reset status
        status <= Resp;
    endrule


    rule sendCore (status == Resp);
        
        CacheIndex idx = getIndex(missReq.addr);
        CacheWordSelect sel = getWordSelect(missReq.addr);
        
        // enqueue load into hit queue
        if (missReq.op == Ld) begin
            hitQ.enq(dataArray[idx][sel]);
            refDMem.commit(missReq, Valid(dataArray[idx]), 
                            Valid(dataArray[idx][sel]));
        end
        else if (missReq.op == Lr) begin
            hitQ.enq(dataArray[idx][sel]);
            refDMem.commit(missReq, Valid(dataArray[idx]),
                            Valid(dataArray[idx][sel]));
            linkAddr <= tagged Valid getLineAddr(missReq.addr);
        end
        
        status <= Ready;

    endrule

    
    rule dng (status != Resp);
        
        //$display("[[Cache]] Downgrade response");
        
        // get response
        CacheMemReq x = ?;
        case (fromMem.first) matches
            tagged Req .req : x = req;
        endcase
        
        // calculate cache index
        CacheWordSelect sel = getWordSelect(x.addr);
        CacheIndex idx = getIndex(x.addr);
        let tag = getTag(x.addr);
        

        if (privArray[idx] > x.state) begin

           // Determine if a valid cache line needs to write back
           Maybe#(CacheLine) line;
           if (privArray[idx] == M) line = Valid(dataArray[idx]);
           else line = Invalid;

           // Send cache line back to main memory
           let addr = {tag, idx, sel, 2'b0};
           toMem.enq_resp( CacheMemResp {child: id, 
                                  addr: addr, 
                                  state: x.state, 
                                  data: line});
            
            // change cache state
            privArray[idx] <= x.state;
        end

        // address has been downgraded
        fromMem.deq;
    endrule
 
 

    method Action req(MemReq r);
        reqQ.enq(r);
        refDMem.issue(r);
    endmethod


    method ActionValue#(Data) resp;
        //$display("[Cache] Processing response");
        hitQ.deq;
        return hitQ.first;
    endmethod


endmodule
