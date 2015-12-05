import ProcTypes::*;
import MemTypes::*;
import Types::*;
import CacheTypes::*;
import MessageFifo::*;
import Vector::*;
import FShow::*;


module mkPPP(MessageGet c2m, MessagePut m2c, WideMem mem, Empty ifc);

    Vector#(CoreNum, Vector#(CacheRows, Reg#(MSI))) childState <- replicateM(replicateM(mkReg(I)));
    Vector#(CoreNum, Vector#(CacheRows, Reg#(CacheTag))) childTag <- replicateM(replicateM(mkRegU));
    Vector#(CoreNum, Vector#(CacheRows, Reg#(Bool))) waitc <- replicateM(replicateM(mkReg(False)));

    Reg#(Bool) missReg <- mkReg(False);

    function Bool isCompatible(MSI a, MSI b) = 
        ((a == I || b == I) || (a == S && b == S));


    rule parentResp (!c2m.hasResp && !missReg);
        
        // get request
        let req = c2m.first.Req;
        
        // get index and tag of address
        let idx = getIndex(req.addr);
        let tag = getTag(req.addr);

        // get child for convinience
        let c = req.child;

        // determine if it is safe to give privledge yet
        Bool safe = True;
        for (Integer i=0; i < valueOf(CoreNum); i=i+1) begin
            if (fromInteger(i) != c) begin
                MSI s = (childTag[i][idx] == tag)? childState[i][idx] : I;
                if (!isCompatible(s, req.state) || waitc[c][idx]) begin
                    safe = False;
                end
            end
        end

        if (safe) begin
        
            // if child state is currently invalid, get proper data to send to
            // child
            MSI s = (childTag[c][idx] == tag)? childState[c][idx] : I;
            if (s != I) begin
                
                // enqueue message to core
                m2c.enq_resp(CacheMemResp {child: c, 
                                      addr:req.addr, 
                                      state:req.state, 
                                      data:Invalid} );

                // update child state and tag
                childState[c][idx] <= req.state;
                childTag[c][idx] <= tag;
            
                // dequeue response
                c2m.deq;
                
            end
            else begin
                // request data from memory
                mem.req(WideMemReq{
                        write_en: '0,
                        addr: req.addr,
                        data: ? } );
                missReg <= True;
            end
            
        end
    
    endrule


    rule dwn (!c2m.hasResp && !missReg);
        
        // get request
        let req = c2m.first.Req;
        
        // get index and tag of address
        let idx = getIndex(req.addr);
        let tag = getTag(req.addr);

        // get child for convinience
        let c = req.child;

        // Look for incompatible children
        Integer send_req = -1;
        for (Integer i=0; i < valueOf(CoreNum); i=i+1) begin
            if (fromInteger(i) != c) begin
                MSI s = (childTag[i][idx] == tag)? childState[i][idx] : I;
                if (!isCompatible(s, req.state) && !waitc[i][idx]) begin
                    if (send_req == -1) begin
                        send_req = i;
                    end
                end
            end
        end

        if (send_req > -1) begin
            waitc[send_req][idx] <= True;
            m2c.enq_req(CacheMemReq 
                        {child: fromInteger(send_req),
                         addr:req.addr,
                         state: (req.state == M? I:S) } );
        end
    endrule

    rule parentDataResp (!c2m.hasResp && missReg);

        // get request
        let req = c2m.first.Req;
        
        // get index and tag of address
        let idx = getIndex(req.addr);
        let tag = getTag(req.addr);

        // get child for convinience
        let c = req.child;

        // get data
        let line <- mem.resp();

        // enqueue message to core
        m2c.enq_resp(CacheMemResp {child: c, 
                                   addr:req.addr, 
                                   state:req.state, 
                                   data:Valid(line)} );

        // update child state and tag
        childState[c][idx] <= req.state;
        childTag[c][idx] <= tag;
    
        // dequeue response
        c2m.deq;
        missReg <= False;

    endrule


    rule dwnRsp (c2m.hasResp);

        // get response
        let resp = c2m.first.Resp;
        c2m.deq;

        // get index and tag of address
        let idx = getIndex(resp.addr);
        let tag = getTag(resp.addr);
        
        // get child for convinience
        let c = resp.child;

        MSI s = (childTag[c][idx] == tag)? childState[c][idx] : I;
        if (s == M) begin
            
            // create enable signal
            Bit#(CacheLineWords) en = '1;

            // write to memory
            mem.req(WideMemReq{
                write_en: en,
                addr: resp.addr,
                data: fromMaybe(?, resp.data) } );

        end
        
        // update information
        childState[c][idx] <= resp.state;
        waitc[c][idx] <= False;
        childTag[c][idx] <= tag;


    endrule


endmodule

