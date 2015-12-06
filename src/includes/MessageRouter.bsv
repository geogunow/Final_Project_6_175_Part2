import Vector::*;
import CacheTypes::*;
import MessageFifo::*;
import Types::*;


module mkMessageRouter(
		Vector#(CoreNum, MessageGet) c2r,
        Vector#(CoreNum, MessagePut) r2c,
        MessageGet m2r,
        MessagePut r2m,
        Empty ifc 
	);

    Reg#(CoreID) start_core <- mkReg(0);

    rule core2mem;

        // pick core, prioritize response
        // round robin - use cycle number or keep a local variable?
        Integer core_select = -1;
        Bool found_resp = False;
        for (Integer i=0; i<valueOf(CoreNum); i=i+1) begin
            
            Integer core_id = mod(fromInteger(i) + start_core, valueOf(CoreNum));

            if (c2r[i].notEmpty) begin
                CacheMemMessage x = c2r[i].first;
                if (x matches tagged Resp .r &&& !found_resp) begin
                    core_select = i;
                    found_resp = True;
                end
                else if (core_select == -1) begin
                    core_select = i;
                end
            end
        end
        
        // transfer message to memory
        if (core_select >= 0) begin
            CacheMemMessage x = c2r[core_select].first;
            case (x) matches
                tagged Resp .resp : r2m.enq_resp(resp);
                tagged Req .req : r2m.enq_req(req);
            endcase
            c2r[core_select].deq;
        end

        if (start_core == valueOf(CoreNum) - 1) start_core <= 0;
        else start_core <= start_core + 1;
    endrule

    rule mem2core;

        // dequeue message from memory and find core ID
        let x = m2r.first;
        m2r.deq;

        // enqueue message into core
        case (x) matches
            tagged Resp .resp : r2c[resp.child].enq_resp(resp);
            tagged Req .req : r2c[req.child].enq_req(req);
        endcase

    endrule

endmodule

