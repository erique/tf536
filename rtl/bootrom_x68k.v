module bootrom_x68k
(
        input		clk,	// bus clock
        input [6:0]	address,	// address in
        output reg [15:0]	data	// data out
);

always @(posedge clk) begin
	case (address)
		7'd0:	data	<=	16'h00ea;
		7'd1:	data	<=	16'h8804;
		7'd2:	data	<=	16'h41fa;
		7'd3:	data	<=	16'hf7fa;
		7'd4:	data	<=	16'h7ce0;
		7'd5:	data	<=	16'h43f8;
		7'd6:	data	<=	16'h2000;
		7'd7:	data	<=	16'h2449;
		7'd8:	data	<=	16'h7002;
		7'd9:	data	<=	16'h1140;
		7'd10:	data	<=	16'h0008;
		7'd11:	data	<=	16'h1140;
		7'd12:	data	<=	16'h000c;
		7'd13:	data	<=	16'h4228;
		7'd14:	data	<=	16'h0010;
		7'd15:	data	<=	16'h4228;
		7'd16:	data	<=	16'h0014;
		7'd17:	data	<=	16'h1146;
		7'd18:	data	<=	16'h0018;
		7'd19:	data	<=	16'h7206;
		7'd20:	data	<=	16'h6124;
		7'd21:	data	<=	16'h117c;
		7'd22:	data	<=	16'h0020;
		7'd23:	data	<=	16'h001c;
		7'd24:	data	<=	16'h7203;
		7'd25:	data	<=	16'h611a;
		7'd26:	data	<=	16'h3e3c;
		7'd27:	data	<=	16'h01ff;
		7'd28:	data	<=	16'h34d0;
		7'd29:	data	<=	16'h51cf;
		7'd30:	data	<=	16'hfffc;
		7'd31:	data	<=	16'h0c11;
		7'd32:	data	<=	16'h0060;
		7'd33:	data	<=	16'h6602;
		7'd34:	data	<=	16'h4ed1;
		7'd35:	data	<=	16'h0846;
		7'd36:	data	<=	16'h0004;
		7'd37:	data	<=	16'h67be;
		7'd38:	data	<=	16'h4e75;
		7'd39:	data	<=	16'h7eff;
		7'd40:	data	<=	16'h1428;
		7'd41:	data	<=	16'h001c;
		7'd42:	data	<=	16'h0302;
		7'd43:	data	<=	16'h56cf;
		7'd44:	data	<=	16'hfff8;
		7'd45:	data	<=	16'h66f0;
		7'd46:	data	<=	16'h588f;
		7'd47:	data	<=	16'h60e6;
		7'd48:	data	<=	16'h0024;
		7'd49:	data	<=	16'h563d;
		7'd50:	data	<=	16'h7466;
		7'd51:	data	<=	16'h3533;
		7'd52:	data	<=	16'h3672;
		7'd53:	data	<=	16'h325f;
		7'd54:	data	<=	16'h3230;
		7'd55:	data	<=	16'h3236;
		7'd56:	data	<=	16'h2d30;
		7'd57:	data	<=	16'h392d;
		7'd58:	data	<=	16'h3238;
		7'd59:	data	<=	16'h5f38;
		7'd60:	data	<=	16'h3033;
		7'd61:	data	<=	16'h6130;
		7'd62:	data	<=	16'h3937;
		default:	data	<=	16'd0;
	endcase
end

endmodule
