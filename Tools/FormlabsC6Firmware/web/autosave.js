// One write at a time; newer edits never get replaced by an older response.
class AutoSave {
    constructor(save,report){this.save=save;this.report=report;this.sequence=0;this.pending=false;this.running=false;this.composing=false;this.blocked=false;}
    change(){this.sequence++;this.pending=true;clearTimeout(this.timer);if(!this.blocked&&!this.composing)this.timer=setTimeout(()=>this.flush(),800);}
    async flush(){clearTimeout(this.timer);if(this.running||this.composing||this.blocked||!this.pending)return;
        const sequence=this.sequence;this.running=true;this.pending=false;
        try{await this.save(sequence);}
        catch(e){this.pending=true;this.blocked=e.conflict===true;this.report(e);return;}
        finally{this.running=false;}
        if(this.pending&&!this.blocked)this.timer=setTimeout(()=>this.flush(),250);
    }
    reset(){clearTimeout(this.timer);this.pending=false;this.blocked=false;}
}
